---
title: "Virtual Threads no Spring Boot 4: aposentei o WebFlux?"
description: >-
  Como Virtual Threads mudam o modelo de concorrência no Spring Boot 4 e o que
  isso significa para o WebFlux na prática: mounting/pinning e o JEP 491, o que
  uma propriedade muda de verdade no runtime, comparação direta entre
  thread-per-request e reativo, exemplo completo de orquestração de crédito com
  RestClient, JDBC e DynamoDB, e checklist de produção.
author: cleiton
date: 2026-06-26 09:00:00 -0300
categories: [Java, Spring Boot]
tags: [virtual threads, project loom, webflux, spring boot, concorrência, jep 491]
---

## 1. Resumo

Durante quase uma década, a resposta canônica para "meu serviço Java não escala porque as threads acabam" foi migrar para programação reativa — no ecossistema Spring, isso significou WebFlux e Project Reactor. O custo era conhecido: um modelo de programação invasivo, stack traces ilegíveis e um ecossistema paralelo (R2DBC, clientes async) que raramente cobria 100% das dependências de um sistema real. Com Virtual Threads finalizadas no JDK 21 (JEP 444), o problema de *pinning* em `synchronized` resolvido no JDK 24 (JEP 491) e o Spring Boot 4.1 tratando o modelo thread-per-request sobre virtual threads como cidadão de primeira classe, a pergunta deixou de ser provocação e virou decisão de arquitetura.

- **Virtual threads eliminam o motivo original de adoção do WebFlux** para a maioria dos serviços I/O-bound: código bloqueante, síncrono e legível volta a escalar para dezenas de milhares de requisições concorrentes.
- **O JEP 491 (JDK 24, herdado pelo JDK 25 LTS) removeu o maior risco operacional**: blocos `synchronized` não fazem mais *pinning* da carrier thread, o que elimina a necessidade de auditar bibliotecas de terceiros à procura de monitores em hot paths.
- **WebFlux não morreu, mas o nicho encolheu**: backpressure fim-a-fim, streaming de dados (SSE, WebSocket massivo, RSocket) e pipelines de composição de fluxos continuam sendo território onde o modelo reativo é genuinamente superior.
- **O gargalo se moveu**: com o teto de threads removido, pool de conexões (HikariCP), rate limits de serviços downstream e bibliotecas pesadas em `ThreadLocal` viram os novos limitadores — e precisam de bulkheads explícitos.
- **Structured Concurrency ainda é preview** (JEP 505 no JDK 25, JEP 525 no JDK 26); para fan-out em produção sem flags de preview, `ExecutorService` com virtual threads resolve.

Se seu time mantém serviços WebFlux que são, na essência, CRUDs e orquestrações de chamadas HTTP/banco — e não pipelines de streaming —, migrar novos serviços para Spring MVC com virtual threads sobre JDK 25 é provavelmente o maior ganho de manutenibilidade por hora de engenharia disponível hoje.

---

## 2. A promessa que nos levou ao WebFlux (e a conta que pagamos)

O modelo clássico do Spring MVC é thread-per-request: cada requisição HTTP ocupa uma thread do pool do Tomcat do início ao fim do processamento. Como threads de plataforma são wrappers de threads do sistema operacional — com stack de ~1 MB e custo real de criação e context switch —, o pool é limitado (200 threads por padrão no Tomcat). Em serviços I/O-bound, isso produz um desperdício estrutural: a thread passa a maior parte do tempo **bloqueada esperando** banco de dados, APIs externas ou filas, mas continua ocupando o slot.

Em um sistema financeiro, o cenário é típico: uma consulta de limite de crédito que chama um bureau externo (200–800 ms de latência), consulta o cadastro no banco relacional e busca parâmetros de política em uma tabela DynamoDB. A thread fica >95% do tempo ociosa, e o serviço satura com poucas centenas de requisições concorrentes — muito antes de esgotar CPU ou rede. As consequências eram bem conhecidas: **saturação precoce sob picos** (abertura de pregão, dia de pagamento), com filas no connector e timeouts em cascata; **custo de infraestrutura inflado** para compensar threads ociosas escalando horizontalmente; e **pressão para adotar modelos assíncronos** que resolvem o problema técnico ao custo de reescrever a forma como o time pensa.

A resposta do ecossistema, a partir de 2017, foi o Spring WebFlux: event loops com poucas threads (Netty), I/O não bloqueante e o contrato `Mono`/`Flux` do Reactor. Funcionou — mas fragmentou o ecossistema. JDBC é bloqueante por especificação, o que exigiu R2DBC; bibliotecas síncronas precisavam ser isoladas em `Schedulers.boundedElastic()`; um único `.block()` esquecido dentro do event loop derrubava o throughput inteiro; e depurar uma `NullPointerException` no meio de um `flatMap` encadeado virou especialidade. Para times de sistemas transacionais — onde legibilidade, auditabilidade e onboarding importam tanto quanto throughput —, o custo cognitivo do reativo sempre foi o elefante na sala.

O Project Loom atacou o problema pela raiz: em vez de mudar o modelo de programação para acomodar threads caras, tornou as threads baratas. Em junho de 2026, com JDK 25 LTS estável, JEP 491 eliminando o pinning de `synchronized` e Spring Boot 4.1.0 (sobre Spring Framework 7.0.8) maduro, o tema deixou de ser aposta e virou default razoável — e é hora de reavaliar onde o WebFlux ainda se justifica.

---

## 3. Como a JVM torna o bloqueio barato: mounting, carriers e o scheduler do Loom

O mecanismo central das virtual threads é o **mounting**: uma virtual thread só consome uma thread de plataforma (a *carrier*) enquanto executa código. Ao encontrar uma operação bloqueante do JDK (`Socket`, `InputStream`, `Thread.sleep`, locks de `java.util.concurrent`), ela é **desmontada** — seu estado vai para o heap e a carrier fica livre para executar outra virtual thread. O agendamento é feito por um `ForkJoinPool` interno da JVM, com paralelismo padrão igual ao número de núcleos. O bloqueio, que era o vilão do modelo thread-per-request, vira operação barata.

| Característica | Platform thread | Virtual thread |
|---|---|---|
| Implementação | Wrapper 1:1 de thread do SO | Objeto gerenciado pela JVM (JDK scheduler) |
| Stack | ~1 MB reservado (configurável via `-Xss`) | Cresce/encolhe sob demanda no heap |
| Custo de criação | Alto (syscall) | Baixíssimo (alocação de objeto) |
| Quantidade viável | Milhares | Milhões |
| Agendamento | Scheduler do SO | `ForkJoinPool` da JVM sobre carrier threads |
| Bloqueio em I/O | Ocupa a thread do SO | Desmonta e libera a carrier thread |
| Pooling | Necessário (recurso caro) | **Anti-pattern** (recurso descartável) |

Duas consequências desse desenho orientam todo o resto do artigo. Primeira: virtual threads otimizam **espera**, não computação — um workload CPU-bound continua limitado pelos núcleos e não ganha nada. Segunda: como criar uma virtual thread custa quase nada, o padrão passa a ser **uma thread nova e descartável por tarefa** (`Executors.newVirtualThreadPerTaskExecutor()`, `Thread.ofVirtual()`), e qualquer tentativa de reutilizá-las em pool trabalha contra o modelo.

---

## 4. JEP 491: o fim do pinning por `synchronized` — e o que ainda pinna

Nem todo bloqueio permitia desmontagem. Até o JDK 23, uma virtual thread que bloqueasse **dentro de um bloco ou método `synchronized`** ficava *pinned*: presa à carrier, que deixava de servir outras virtual threads. Como o scheduler tem, por padrão, um número de carriers igual ao de núcleos, pinning frequente causava degradação, starvation e — em casos documentados em produção — deadlocks. O problema raramente estava no código da aplicação: estava em drivers JDBC, em `ConcurrentHashMap.computeIfAbsent` (usado por bibliotecas de cache como Caffeine) e em clientes HTTP que usavam `synchronized` internamente. A recomendação da época — trocar `synchronized` por `ReentrantLock` — dependia dos mantenedores de cada biblioteca.

O **JEP 491 (JDK 24)** mudou a implementação de monitores na JVM para rastrear a posse por virtual thread, não por carrier. Resultado: `synchronized` deixou de fazer pinning, sem nenhuma mudança de código, e o JDK 25 LTS herdou a correção. Casos residuais permanecem — chamadas nativas (JNI/FFM) que bloqueiam e bloqueio dentro de inicializadores de classe (este último parcialmente endereçado no JDK 26) — e continuam observáveis pelo evento `jdk.VirtualThreadPinned` no JFR. Na prática, o pinning saiu da lista de bloqueadores de adoção e entrou na lista de itens de monitoramento.

| JDK | Entrega | Impacto |
|---|---|---|
| 21 (LTS, 2023) | JEP 444 — Virtual Threads finais | Modelo disponível, mas pinning por `synchronized` era risco real |
| 24 (2025) | JEP 491 — `synchronized` sem pinning | Remove o principal bloqueador de produção |
| 25 (LTS, 2025) | Herda JEP 491; JEP 506 — Scoped Values finais | Baseline recomendada para adoção séria |
| 26 (2026) | JEP 525 — Structured Concurrency (6º preview); menos pinning em class-init | Fan-out estruturado ainda em amadurecimento |

É essa cronologia que muda a resposta da pergunta do título entre 2023 e 2026: no JDK 21, adotar virtual threads exigia auditar o grafo de dependências inteiro à procura de monitores em hot paths; no JDK 25, exige monitorar um evento de JFR.

---

## 5. Uma propriedade, outro runtime: o que muda de verdade no Spring Boot 4.1

Desde o Boot 3.2 — e mantido no Boot 4.x —, uma única propriedade ativa o modo:

```yaml
spring:
  threads:
    virtual:
      enabled: true
```

Com ela, o Spring Boot reconfigura os pontos de execução para criar uma virtual thread por tarefa, em vez de usar pools: o executor de requisições do Tomcat, o `applicationTaskExecutor` usado por `@Async`, o scheduler de `@Scheduled`, e os listeners de integrações suportadas (RabbitMQ, Kafka, entre outros). O modelo de programação **não muda**: seus controllers, services e repositórios continuam síncronos e bloqueantes — só que agora bloquear é barato.

```java
// Nenhuma abstração nova: um service síncrono comum.
// A escalabilidade vem do runtime, não do código.
@Service
public class LimiteService {

    public LimiteCredito consultar(String cpf) {
        var conta = contaRepository.buscarPorCpf(cpf);   // JDBC bloqueante — ok
        var score = bureauClient.consultarScore(cpf);    // HTTP bloqueante — ok
        return politica.calcular(conta, score);
    }
}
```

É exatamente essa a proposta de valor: **escalabilidade de reativo com o modelo mental de sempre** — stack traces completos, debugger funcional, `@Transactional` e `try/catch` se comportando como sempre, e o ecossistema inteiro (JDBC, JPA, clientes síncronos do AWS SDK) disponível sem adaptadores. O custo de migração a partir de MVC clássico se resume à propriedade e a uma rodada de testes de carga.

Mas a propriedade não é mágica, e é aqui que mora a parte que os benchmarks de blog costumam omitir: o Tomcat deixa de impor um teto de concorrência, e **tetos implícitos deixam de existir junto**. Nada impede 50 mil virtual threads de esmagarem um downstream com rate limit contratual; bibliotecas que cacheiam estado caro em `ThreadLocal` (MDC pesado, session caches) assumem threads longevas e escassas — o oposto do novo mundo; e o pool de conexões JDBC vira o limitador real de concorrência contra o banco. Mais concorrência aparente pode significar apenas fila maior e p99 pior, se o downstream não acompanhar. Esses deslocamentos de gargalo são o assunto das seções 8 e 9.

---

## 6. O território que resta ao WebFlux: backpressure, streams e composição temporal

O WebFlux não escala "porque é assíncrono", e sim porque **nenhuma thread espera**: um pequeno conjunto de event loops (Netty) multiplexa milhares de conexões via I/O não bloqueante, e o trabalho é descrito como pipelines declarativos (`Mono`/`Flux`) que só executam quando há dados. Virtual threads igualaram a parte da escalabilidade — mas duas propriedades do modelo reativo **não** são replicadas automaticamente:

- **Backpressure nativo**: o consumidor sinaliza ao produtor quanta demanda suporta (`request(n)` da spec Reactive Streams). Em pipelines de streaming — consumir um tópico Kafka, transformar e servir via SSE — isso é controle de fluxo fim-a-fim, de graça. No mundo das virtual threads, o equivalente é artesanal: semáforos, filas limitadas, bulkheads.
- **Composição de fluxos**: operadores como `window`, `buffer`, `retryWhen`, `merge`, `sample` expressam lógica temporal e de particionamento de streams que, em código imperativo, exigiria máquinas de estado manuais.

```java
// O tipo de retorno carrega o modelo: tudo que toca este fluxo
// precisa ser não bloqueante ou explicitamente isolado.
@Service
public class ExtratoStreamService {

    public Flux<Lancamento> streamLancamentos(String conta) {
        return lancamentoRepository.findByConta(conta)   // R2DBC
            .window(Duration.ofSeconds(1))               // particionamento temporal
            .flatMap(this::enriquecer)
            .onBackpressureBuffer(1_000);                // controle de fluxo explícito
    }
}
```

O preço segue o mesmo de sempre, e ele é permanente, não um custo único de adoção: **contaminação viral** do tipo de retorno (`Mono`/`Flux` sobem por toda a pilha, e um `.block()` acidental degrada o serviço inteiro); **depuração difícil** (traces fragmentados, ferramentas próprias como Reactor Debug Agent e BlockHound); **ecossistema paralelo obrigatório** (JDBC/JPA fora do caminho quente, R2DBC cobrindo menos features que os drivers maduros); **propagação explícita de contexto** para MDC, tracing e security; e **onboarding mais caro**, porque o pool de devs fluentes em Reactor é menor.

A leitura honesta: onde o problema **é** um fluxo — streaming de cotações, SSE para milhares de conexões, ingestão de eventos com ritmos incompatíveis entre produtor e consumidor, RSocket —, esses custos compram algo que virtual threads não oferecem. Onde o problema é uma sequência de chamadas, compram nada.

---

## 7. Lado a lado: quando cada modelo vence

| Dimensão | MVC + Virtual Threads | WebFlux (Reactor) |
|---|---|---|
| Modelo de programação | Imperativo, síncrono | Declarativo, assíncrono |
| Curva de aprendizado | Nula para devs Java | Alta (Reactor + disciplina de não bloquear) |
| Escalabilidade I/O-bound | Alta (milhões de threads baratas) | Alta (event loop + NIO) |
| Backpressure | Manual (semáforos, bulkheads, filas) | Nativo (Reactive Streams) |
| Streaming (SSE, WebSocket, Kafka→HTTP) | Possível, mas artesanal | Ponto forte |
| Ecossistema de dados | JDBC/JPA completos | R2DBC (subconjunto) |
| Observabilidade e debug | Stack traces normais, JFR, thread dumps por escopo | Traces fragmentados, ferramentas específicas |
| `ThreadLocal`/MDC | Funciona (com ressalvas de custo) | Propagação explícita de contexto |
| Risco operacional dominante | Saturar downstream sem perceber; pinning residual (JNI) | `.block()` acidental; starvação do event loop |
| Custo de migração de MVC clássico | Uma propriedade + testes de carga | Reescrita |
| Manutenção de longo prazo | Barata | Cara |
| Baseline recomendada | JDK 25 LTS (JEP 491 incluso) | JDK 17+ |

**Síntese de decisão**: as abordagens deixaram de competir pelo mesmo território. Virtual threads venceram a disputa pelo caso majoritário — serviços request/response I/O-bound, orquestrações e CRUDs transacionais — porque entregam a mesma escalabilidade com uma fração do custo de manutenção. O WebFlux se retraiu para o território onde seu modelo é a própria feature: quando o problema **é** um fluxo, e não uma sequência de chamadas. A pergunta de arquitetura correta em 2026 não é "reativo ou bloqueante?", e sim "meu domínio é request/response ou é stream?".

---

## 8. Na prática: análise de limite de crédito com fan-out em virtual threads

Cenário realista: um serviço de crédito que, para cada solicitação, precisa de três fontes — cadastro da conta no PostgreSQL (JDBC), score no bureau externo (HTTP) e parâmetros de política de crédito no DynamoDB (AWS SDK síncrono). As duas últimas são independentes entre si e podem ser paralelizadas. O bureau tem rate limit contratual, então a concorrência contra ele precisa de teto explícito — exatamente o tipo de backpressure manual que o modelo exige.

### 8.1 Build (Maven)

```xml
<project>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.1.0</version> <!-- Spring Framework 7.0.8, Tomcat 11 -->
  </parent>

  <properties>
    <java.version>25</java.version> <!-- LTS; herda o JEP 491 do JDK 24 -->
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>software.amazon.awssdk</groupId>
        <artifactId>bom</artifactId>
        <version>2.47.4</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId> <!-- MVC + Tomcat -->
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-jdbc</artifactId>
    </dependency>
    <dependency>
      <groupId>org.postgresql</groupId>
      <artifactId>postgresql</artifactId> <!-- versão gerida pelo Boot 4.1.0 -->
    </dependency>
    <dependency>
      <groupId>software.amazon.awssdk</groupId>
      <artifactId>dynamodb-enhanced</artifactId> <!-- cliente SÍNCRONO basta -->
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
  </dependencies>
</project>
```

Pontos de atenção após o build:

- **JDK 25, não 21.** No JDK 21 o código compila e roda, mas `synchronized` em dependências ainda faz pinning — a classe de incidentes que o JEP 491 eliminou só desaparece no 24+.
- **Boot 4.x removeu o Undertow**; o exemplo assume Tomcat 11. Se você vinha de Undertow no Boot 3.x, essa migração precede esta.
- **Cliente DynamoDB síncrono de propósito**: com virtual threads, o cliente assíncrono (Netty) do AWS SDK deixa de ser necessário para escalar — e o síncrono simplifica o código. O SDK assíncrono continua válido em contexto WebFlux.
- **Não declare pools de threads customizados** para os fluxos de requisição; a propriedade do Boot cuida do executor do Tomcat e do `applicationTaskExecutor`.

### 8.2 Configuração e código

```yaml
# application.yaml
spring:
  threads:
    virtual:
      enabled: true          # Tomcat, @Async e @Scheduled passam a usar virtual threads
  datasource:
    hikari:
      maximum-pool-size: 30  # ATENÇÃO: este é o novo teto real de concorrência no banco.
                             # Virtual threads não multiplicam conexões — dimensione
                             # pelo que o PostgreSQL suporta, não pelo tráfego HTTP.
```

```java
package br.com.exemplo.credito;

import java.util.concurrent.*;
import org.springframework.stereotype.Service;

@Service
public class LimiteService {

    private final ContaRepository contaRepository;
    private final BureauCreditoClient bureauClient;
    private final PoliticaCreditoRepository politicaRepository;

    // Bulkhead explícito: o bureau tem rate limit contratual de 50 chamadas
    // concorrentes. Virtual threads removeram o teto implícito que o pool do
    // Tomcat impunha — sem este semáforo, um pico de tráfego viraria um
    // ataque de negação de serviço contra o parceiro.
    private final Semaphore bureauBulkhead = new Semaphore(50);

    public LimiteService(ContaRepository contaRepository,
                         BureauCreditoClient bureauClient,
                         PoliticaCreditoRepository politicaRepository) {
        this.contaRepository = contaRepository;
        this.bureauClient = bureauClient;
        this.politicaRepository = politicaRepository;
    }

    public LimiteCredito analisar(String cpf) throws InterruptedException {
        // Fan-out com executor de virtual threads: uma thread nova e descartável
        // por subtarefa. Sem preview features (Structured Concurrency ainda é
        // JEP 525/preview no JDK 26); try-with-resources garante que nenhuma
        // subtarefa vaza além do escopo da requisição.
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {

            Future<ScoreBureau> scoreFuture = executor.submit(() -> {
                bureauBulkhead.acquire(); // bloquear aqui é barato: a VT desmonta
                try {
                    return bureauClient.consultarScore(cpf);
                } finally {
                    bureauBulkhead.release();
                }
            });

            Future<PoliticaCredito> politicaFuture =
                executor.submit(() -> politicaRepository.buscarVigente());

            // A consulta ao cadastro roda na própria virtual thread da requisição:
            // paralelizar as 3 chamadas não compensaria segurar conexão JDBC
            // ociosa enquanto o bureau responde — conexões são o recurso escasso.
            Conta conta = contaRepository.buscarPorCpf(cpf);

            try {
                ScoreBureau score = scoreFuture.get(2, TimeUnit.SECONDS);
                PoliticaCredito politica = politicaFuture.get(500, TimeUnit.MILLISECONDS);
                return politica.calcularLimite(conta, score);
            } catch (TimeoutException e) {
                // Falha rápida com contrato claro: melhor negar com fallback
                // conservador do que enfileirar indefinidamente em dia de pico.
                throw new AnaliseIndisponivelException(cpf, e);
            } catch (ExecutionException e) {
                throw new AnaliseFalhouException(cpf, e.getCause());
            }
        } // close() aguarda/cancela pendências: sem threads órfãs
    }
}
```

```java
package br.com.exemplo.credito;

import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

@Component
public class BureauCreditoClient {

    private final RestClient restClient;

    // RestClient (síncrono, Spring 6.1+) é o par natural do modelo:
    // API fluente moderna sem arrastar WebClient/Reactor para o classpath
    // de um serviço que não é reativo.
    public BureauCreditoClient(RestClient.Builder builder) {
        this.restClient = builder
            .baseUrl("https://bureau.exemplo.com.br")
            .build();
    }

    public ScoreBureau consultarScore(String cpf) {
        // Chamada bloqueante deliberada: a virtual thread desmonta durante a
        // espera de rede e a carrier atende outras requisições. O "custo do
        // bloqueio" que justificava o WebFlux não existe mais aqui.
        return restClient.get()
            .uri("/v2/score/{cpf}", cpf)
            .retrieve()
            .body(ScoreBureau.class);
    }
}
```

```java
package br.com.exemplo.credito;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class ContaRepository {

    private final JdbcClient jdbcClient;

    public ContaRepository(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    public Conta buscarPorCpf(String cpf) {
        // JDBC puro, sem R2DBC: o driver bloqueia, a VT desmonta, o Hikari
        // governa a concorrência real contra o banco. A fronteira de
        // escalabilidade é o maximum-pool-size — e deve ser, porque é o
        // PostgreSQL quem dita quantas sessões simultâneas aguenta.
        return jdbcClient.sql("""
                SELECT numero, titular_cpf, saldo, data_abertura
                FROM conta WHERE titular_cpf = :cpf
                """)
            .param("cpf", cpf)
            .query(Conta.class)
            .single();
    }
}
```

**O que este exemplo demonstra na prática:**

1. **A migração é de runtime, não de código**: controller, service e repository são Java síncrono comum; a única mudança estrutural é a propriedade `spring.threads.virtual.enabled`.
2. **Backpressure manual onde importa**: o `Semaphore` no bureau é o substituto explícito do que o Reactor daria implicitamente — e torna o limite auditável e contratual.
3. **Fan-out seguro sem preview features**: `Executors.newVirtualThreadPerTaskExecutor()` em try-with-resources dá paralelismo estruturado suficiente enquanto o JEP 525 não estabiliza.
4. **O pool de conexões é o novo contrato de capacidade**: o comentário no `application.yaml` não é detalhe — dimensionar Hikari pelo banco, e não pelo tráfego, é a decisão que evita o clássico "throughput subiu, p99 explodiu".
5. **Escolha deliberada de clientes síncronos** (RestClient, DynamoDB sync): menos dependências, menos modelos mentais, mesmo resultado de escala.

---

## 9. Onde os times tropeçam depois de ligar a chave

1. **Fazer pool de virtual threads.** Reutilizar VTs via `FixedThreadPool` destrói o modelo: elas são descartáveis por design. Para limitar concorrência, use `Semaphore` ou bulkheads — nunca um pool.
2. **Adotar em JDK 21 e assumir que "virtual threads estão prontas".** Sem o JEP 491, `synchronized` em qualquer dependência (driver JDBC, cache, cliente HTTP) faz pinning sob carga. Mitigação: baseline JDK 25 LTS; se estiver preso ao 21, audite com `jdk.VirtualThreadPinned` antes de ligar em produção.
3. **Tratar virtual threads como aceleração de CPU.** Elas otimizam *espera*, não *computação*. Workloads CPU-bound (criptografia, cálculo de risco em lote) não ganham nada — e o paralelismo continua limitado pelos núcleos. Mitigação: mantenha CPU-bound em pools de platform threads dimensionados por núcleo.
4. **Ignorar que o gargalo se moveu para o pool de conexões.** 20 mil requisições concorrentes disputando 30 conexões Hikari não é escalabilidade — é fila com outro nome, e p99 degradado. Mitigação: dimensione o pool pelo banco, imponha timeouts de aquisição agressivos e monitore `hikaricp.connections.pending`.
5. **Derrubar o downstream por excesso de gentileza.** Sem o teto natural do pool do Tomcat, seu serviço repassa picos integralmente para parceiros e serviços internos. Mitigação: semáforos/bulkheads por dependência e rate limiting na borda — o exemplo da seção 8 existe por isso.
6. **Carregar `ThreadLocal` pesado para o novo mundo.** Bibliotecas que cacheiam objetos caros por thread (buffers, sessões, MDC gigante) assumem poucas threads longevas; com milhões de VTs curtas, isso vira churn de alocação. Mitigação: MDC mínimo, e Scoped Values (JEP 506, final no JDK 25) para contexto imutável em código novo.
7. **Misturar os dois mundos sem fronteira.** Chamar `.block()` de código Reactor dentro de um serviço VT "porque funciona" cria dependência dupla de modelo e complica raciocínio de contexto/transação. Mitigação: por serviço, um modelo só; na fronteira entre serviços, HTTP resolve.
8. **Monitorar pinning com ferramenta morta.** `-Djdk.tracePinnedThreads` foi removido; quem confiava nele ficou cego. Mitigação: JFR (`jdk.VirtualThreadPinned`, `jdk.VirtualThreadSubmitFailed`) e thread dumps via `jcmd Thread.dump_to_file -format=json`.

---

## 10. Aposentei? Decisão orientada a engenharia

**Use Spring MVC + Virtual Threads como default para serviços novos** request/response e I/O-bound: orquestrações de crédito e pagamento, BFFs, APIs transacionais, integrações com parceiros. Sobre JDK 25 e Boot 4.1, esse arranjo entrega a escalabilidade que motivava o WebFlux com o custo de manutenção do Java de sempre — e em sistemas financeiros, onde auditabilidade e clareza de fluxo valem dinheiro, isso pesa mais que qualquer benchmark.

**Use (ou mantenha) WebFlux quando o problema for um fluxo, não uma sequência**: streaming de cotações via SSE/WebSocket para grandes volumes de conexões, backpressure fim-a-fim entre sistemas com ritmos incompatíveis, composição temporal de eventos, RSocket. Nesses domínios, o modelo reativo não é overhead — é a solução; virtual threads não oferecem substituto equivalente para `request(n)`. E não reescreva WebFlux saudável por ideologia: serviço reativo estável, com time fluente e função de streaming, não é dívida técnica — migre quando tocar por outro motivo, e apenas se o domínio for request/response.

**Adie a adoção de virtual threads apenas se** você está preso a JDK ≤ 23 por política de plataforma (o risco de pinning por `synchronized` volta inteiro), ou se seu hot path depende de bibliotecas com chamadas nativas bloqueantes longas (JNI/FFM) — os casos residuais que o JEP 491 não cobre. Nesses cenários, valide com JFR em carga antes de ligar a chave.

**Na segunda-feira**: escolha um serviço I/O-bound de orquestração (maior ganho, menor risco), garanta JDK 25 no pipeline, ligue `spring.threads.virtual.enabled=true` em staging, rode o mesmo teste de carga de antes e compare throughput, p99 e `hikaricp.connections.pending`. Declare a capacidade de cada dependência como código (semáforo para parceiros com rate limit, pool dimensionado pelo banco, rate limiter na borda), instrumente `jdk.VirtualThreadPinned` no JFR e registre a decisão em um ADR com os critérios de exceção que mantêm o WebFlux. Trate Structured Concurrency como aposta futura: `ExecutorService` em try-with-resources é o padrão estável até o JEP 525 finalizar.

Respondendo à pergunta do título com precisão de engenharia: não aposentei o WebFlux — aposentei o WebFlux *como resposta padrão à escassez de threads*, que foi o motivo pelo qual a maioria de nós o adotou. O que o Loom fez não foi vencer o reativo, e sim devolver cada modelo ao seu problema: threads baratas para request/response, streams reativos para streaming. Frameworks não se aposentam por marketing; se reposicionam quando a plataforma embaixo deles muda. Foi o que aconteceu.

---

## Checklist para implementação em produção

**Pré-requisitos**
- [ ] JDK 25 LTS (ou 24+) validado no pipeline e no runtime de produção
- [ ] Spring Boot 4.1.x confirmado (migração de Undertow concluída, se aplicável)
- [ ] Inventário de dependências com chamadas nativas (JNI/FFM) em hot paths
- [ ] Serviço classificado: request/response (candidato) vs. streaming (mantém WebFlux)

**Build e CI**
- [ ] `spring-boot-starter-parent` 4.1.0 e `java.version` 25 no build
- [ ] Nenhuma preview feature habilitada (Structured Concurrency fora do build de produção)
- [ ] Teste de carga automatizado comparando antes/depois da ativação (throughput, p50/p99)

**Código**
- [ ] `spring.threads.virtual.enabled=true` aplicado e revisado
- [ ] Nenhum pool de virtual threads; fan-out via `newVirtualThreadPerTaskExecutor` em try-with-resources
- [ ] Timeouts explícitos em todas as chamadas externas (HTTP, DynamoDB, JDBC)
- [ ] `ThreadLocal` auditado; contexto novo usando Scoped Values quando fizer sentido

**Fronteiras**
- [ ] Bulkhead (semáforo) por dependência externa com rate limit contratual
- [ ] `maximum-pool-size` do Hikari dimensionado pelo banco, com `connection-timeout` agressivo
- [ ] Rate limiting na borda para não repassar picos integralmente aos downstreams

**Governança**
- [ ] ADR registrando a escolha do modelo de concorrência e os critérios de exceção (WebFlux)
- [ ] Dashboards com `jdk.VirtualThreadPinned`, `jdk.VirtualThreadSubmitFailed` e métricas de pool
- [ ] Ordem de adoção definida (orquestrações → CRUDs → avaliar streaming caso a caso)
- [ ] Plano de revisão quando Structured Concurrency for finalizada (previsto para JDK 27)

---

*Referências primárias: JEP 444 — Virtual Threads (openjdk.org/jeps/444); JEP 491 — Synchronize Virtual Threads without Pinning (openjdk.org/jeps/491); JEP 505 e JEP 525 — Structured Concurrency, previews (openjdk.org/jeps/505, openjdk.org/jeps/525); JEP 506 — Scoped Values (openjdk.org/jeps/506); documentação oficial do Spring Boot 4.1 — seção "Virtual Threads" e release notes (docs.spring.io/spring-boot e github.com/spring-projects/spring-boot/wiki); anúncio do Spring Boot 4.1.0 no blog oficial (spring.io/blog); documentação do Spring Framework 7 — Web on Servlet Stack e Web on Reactive Stack (docs.spring.io/spring-framework); Oracle Java SE 25 Core Libraries — Virtual Threads (docs.oracle.com); AWS SDK for Java 2.x Developer Guide (docs.aws.amazon.com/sdk-for-java).*
