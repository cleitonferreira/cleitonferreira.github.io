---
title: "Spring Boot 4 e OpenTelemetry: observabilidade nativa sem java-agent, do @Observed ao Grafana LGTM"
description: >-
  Como o Spring Boot 4 exporta logs, métricas e traces via OTLP sem agente:
  a ponte Micrometer Observation → OpenTelemetry, propagação de contexto W3C
  entre serviços e threads, demo executável com três microsserviços e stack
  Grafana LGTM, testes da própria instrumentação e checklist de produção.
author: cleiton
date: 2026-07-23 09:00:00 -0300
categories: [Java, Spring Boot]
tags: [opentelemetry, observabilidade, micrometer, tracing, otlp, grafana]
---

## 1. Resumo

Durante anos, colocar telemetria em uma aplicação JVM significou anexar o java-agent do OpenTelemetry e torcer para a instrumentação por bytecode não conflitar com o resto do classpath. O Spring Boot 4 consolida o caminho alternativo: **instrumentação nativa**, em que a própria aplicação produz logs, métricas e traces correlacionados e os exporta via OTLP — sem agente, sem bytecode mágico, com tudo visível no `pom.xml` e depurável como qualquer outro código. Este artigo destrincha esse caminho usando um projeto executável de três microsserviços, o [spring-boot-opentelemetry](https://github.com/cleitonferreira/spring-boot-opentelemetry).

- **Uma abstração, três sinais**: a Micrometer Observation API (`@Observed`) gera métrica, span e correlação de log a partir de uma única instrumentação — a ponte para o OpenTelemetry é responsabilidade dos starters, não do seu código.
- **Propagação de contexto de ponta a ponta**: o `traceparent` W3C atravessa os três serviços via `RestClient`/HTTP interface clients, e `spring.task.execution.propagate-context=true` mantém o trace íntegro mesmo em orquestração assíncrona entre threads.
- **Interoperabilidade com a API pura do OpenTelemetry**: código instrumentado direto com `Tracer`/`Meter` do OTel participa do mesmo trace iniciado pelo Micrometer — os dois mundos convivem.
- **Stack de visualização em um comando**: `docker compose up -d` sobe o Grafana LGTM (Loki, Grafana, Tempo, Mimir) recebendo OTLP nas portas 4317/4318.
- **Instrumentação também se testa**: `TestObservationRegistry`, `InMemorySpanExporter` e testes de propagação garantem que a telemetria não regride silenciosamente.

Se você está começando um serviço Spring Boot novo em 2026, comece pela instrumentação nativa com os starters — e deixe o java-agent para o legado que você não pode tocar.

---

## 2. Duas rotas para telemetria na JVM: java-agent vs instrumentação nativa

Antes de olhar código, vale explicitar a decisão de arquitetura que este artigo defende, porque ela é frequentemente tomada por inércia.

O **java-agent do OpenTelemetry** (`opentelemetry-javaagent.jar`) instrumenta por manipulação de bytecode em tempo de carga: você adiciona `-javaagent` na JVM e ganha instrumentação de dezenas de bibliotecas sem tocar no código. A **instrumentação nativa** do Spring Boot inverte a responsabilidade: a telemetria nasce dentro do framework, via Micrometer Observation, e o OpenTelemetry entra como SDK de exportação — dependências declaradas, beans visíveis, comportamento reproduzível em teste.

| Critério | Java-agent OTel | Nativa (Boot + Micrometer) |
|---|---|---|
| **Esforço inicial** | Mínimo (flag na JVM) | Baixo (starters + propriedades) |
| **Visibilidade do mecanismo** | Opaca (bytecode em runtime) | Total (beans, aspectos, filtros) |
| **Instrumentação de domínio** | Requer API/extensões à parte | `@Observed` e Observation API de primeira classe |
| **Overhead** | Maior na inicialização (transformação de classes); startup mais lento | Diluído no framework; sem fase de retransformação |
| **Compatibilidade** | Sensível a versões de libs e à JVM (CDS, AOT, native image) | Evolui junto com o Boot; compatível com AOT/GraalVM |
| **Testabilidade da telemetria** | Difícil (agente não roda no teste unitário) | Direta (`TestObservationRegistry`, exporters em memória) |
| **Cobertura de libs de terceiros** | Ampla (centenas de instrumentações prontas) | A do ecossistema Spring/Micrometer |
| **Aplicável a código que não se pode alterar** | Sim | Não |

**Síntese de decisão**: em serviços Spring Boot que você controla, a rota nativa ganha em previsibilidade, testabilidade e alinhamento com o ciclo de release do framework. O agente permanece imbatível para sistemas legados fechados ou para uniformizar telemetria em um parque poliglota onde nem tudo é Spring. Misturar os dois no mesmo processo é anti-pattern (seção 9).

---

## 3. O laboratório: três serviços, uma stack LGTM

O projeto [spring-boot-opentelemetry](https://github.com/cleitonferreira/spring-boot-opentelemetry) implementa o menor sistema distribuído que ainda exibe os problemas reais de observabilidade: orquestração, chamadas HTTP entre serviços, banco de dados, erro proposital e concorrência.

```
                 ┌──────────────────┐
    curl ──────► │  hello-service   │ :8080  (orquestrador)
                 └───────┬──────────┘
             ┌───────────┴─────────────┐
             ▼                         ▼
   ┌──────────────────┐      ┌──────────────────┐
   │   user-service   │:8081 │ greeting-service │ :8082
   │  (H2 + Flyway)   │      │  (saudações)     │
   └──────────────────┘      └──────────────────┘
             │                         │
             └────────────┬────────────┘
                          ▼  OTLP (4317/4318)
                ┌───────────────────┐
                │   Grafana LGTM    │ :3000
                │ Loki·Tempo·Mimir  │
                └───────────────────┘
```

O [hello-service](https://github.com/cleitonferreira/spring-boot-opentelemetry/tree/main/hello-service) responde `GET /api/{userId}`: busca o usuário no user-service, a saudação (negociada por `Accept-Language`) no greeting-service e combina os dois — "Hallo Moritz". Um módulo [shared](https://github.com/cleitonferreira/spring-boot-opentelemetry/tree/main/shared) concentra a configuração de observabilidade comum.

### 3.1 Versões e build

O projeto roda sobre **Spring Boot 4.1.0-M4** (Spring Framework 7.0.6) e **Java 25**. O trecho relevante do `pom.xml` de cada serviço mostra a novidade estrutural do Boot 4 — starters modulares, um por tecnologia, substituindo os agregadões do Boot 3:

```xml
<!-- hello-service/pom.xml (trecho) -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-opentelemetry</artifactId> <!-- SDK OTel + exporters OTLP autoconfigurados -->
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-micrometer-metrics</artifactId> <!-- métricas Micrometer -->
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-aspectj</artifactId> <!-- habilita o aspecto de @Observed -->
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webmvc</artifactId> <!-- Boot 4: modular, antes era -web -->
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-restclient</artifactId>
</dependency>

<!-- appender que envia logs do Logback para o SDK OpenTelemetry -->
<dependency>
    <groupId>io.opentelemetry.instrumentation</groupId>
    <artifactId>opentelemetry-logback-appender-1.0</artifactId>
    <version>2.25.0-alpha</version>
</dependency>
```

**Pontos de atenção:**

- `4.1.0-M4` é um **milestone**. Para produção, fique na linha GA mais recente do Boot 4 — os conceitos deste artigo valem igualmente, mas nomes de propriedades de export OTLP foram reorganizados entre 3.x e 4.x (`management.opentelemetry.*` para logs/traces, `management.otlp.metrics.export.*` para métricas).
- O sufixo `-alpha` do appender Logback indica instabilidade **de API**, não de runtime — é o status atual de toda a família `opentelemetry-*-instrumentation`.
- O exportador OTLP traz `protobuf-java`, que ainda usa `sun.misc.Unsafe`; no JDK 24+ (JEP 498) isso gera warnings. O projeto silencia com `--sun-misc-unsafe-memory-access=allow` no plugin do Boot — anote essa flag antes de migrar para Java 25.

### 3.2 As propriedades que ligam tudo

```properties
# application.properties (comum aos três serviços)
spring.task.execution.propagate-context=true      # trace sobrevive à troca de thread (seção 5)
management.observations.annotations.enabled=true  # habilita @Observed via aspecto

# Apenas para demonstração — em produção, amostre (seção 9)
management.tracing.sampling.probability=1.0
management.otlp.metrics.export.step=10s
```

Nenhuma URL de collector aparece: com a stack LGTM em `localhost`, os defaults OTLP (`http://localhost:4318/v1/{traces,metrics,logs}`) resolvem. Em ambientes reais, os endpoints são explicitados via `management.opentelemetry.tracing.export.otlp.endpoint`, `management.opentelemetry.logging.export.otlp.endpoint` e `management.otlp.metrics.export.url`.

---

## 4. Uma abstração para três sinais: Micrometer Observation

A peça conceitual central não é do OpenTelemetry — é do Micrometer. Uma **Observation** é um evento de negócio instrumentado uma única vez; *handlers* registrados decidem o que ela vira: um timer de métrica, um span de trace, entradas de log correlacionadas. O `spring-boot-starter-opentelemetry` pluga os handlers que convertem observações em spans OTel e as exportam via OTLP.

No projeto, a instrumentação de domínio é declarativa. Do [HelloService](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/hello-service/src/main/java/com/example/hello/HelloService.java):

```java
@Observed(name = "say-hello")
public String sayHello(@ObservationKeyValue("locale") Locale locale,
                       @ObservationKeyValue("user.id") long userId) {
    ...
}
```

### 4.1 Três detalhes que só se descobrem instrumentando

O projeto tem [testes que verificam a própria instrumentação](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/greeting-service/src/test/java/com/example/greeting/GreetingSpanTest.java), e eles revelam comportamentos que a documentação não deixa óbvios:

1. **O `name` do `@Observed` nomeia a observação e a métrica — não o span.** O span gerado por `@Observed(name = "greeting.get")` chama-se `GreetingService#getGreeting` (o *contextual name* padrão do aspecto, `Classe#método`). Se seus dashboards do Tempo buscam spans pelo nome da anotação, não vão encontrar nada.
2. **`@ObservationKeyValue` é de alta cardinalidade por padrão.** O valor vai para o span como atributo, mas **não** vira tag de métrica. É uma proteção deliberada: `user.id` como tag de métrica explodiria a base de séries temporais. As únicas tags de baixa cardinalidade adicionadas pelo aspecto são `class` e `method`.
3. **Amostragem decide se o span existe; a métrica existe sempre.** Com `sampling.probability` menor que 1.0, a mesma observação continua alimentando o timer, mas só uma fração vira span — por isso métricas são a fonte para SLO e traces são a fonte para diagnóstico.

### 4.2 Cardinalidade como decisão de contrato: um exemplo transacional

Em sistemas financeiros a distinção baixa/alta cardinalidade não é detalhe — é o que separa uma conta de observabilidade sustentável de uma catástrofe de billing. A Observation API programática deixa a fronteira explícita:

```java
package br.com.exemplo.credito;

import io.micrometer.observation.Observation;
import io.micrometer.observation.ObservationRegistry;
import org.springframework.stereotype.Service;

@Service
public class LimiteService {

    private final ObservationRegistry registry;
    private final LimiteRepository limiteRepository;

    public LimiteService(ObservationRegistry registry, LimiteRepository limiteRepository) {
        this.registry = registry;
        this.limiteRepository = limiteRepository;
    }

    public AvaliacaoLimite avaliar(String contaId, ProdutoCredito produto) {
        return Observation.createNotStarted("credito.limite.avaliar", this.registry)
            // BAIXA cardinalidade → vira tag da métrica credito.limite.avaliar.
            // Contrato: só valores enumeráveis (produto tem ~5 valores possíveis).
            .lowCardinalityKeyValue("produto", produto.codigo())
            // ALTA cardinalidade → só atributo do span, nunca tag de métrica.
            // contaId tem milhões de valores; como tag, cada conta criaria
            // uma série temporal nova no Mimir/Prometheus.
            .highCardinalityKeyValue("conta.id", contaId)
            .observe(() -> this.limiteRepository.avaliar(contaId, produto));
    }
}
```

A regra prática: **tag de métrica responde "quantos e quão rápido, por categoria"; atributo de span responde "o que aconteceu com este caso específico"**. Quando um analista precisa investigar a conta X, ele parte do trace (Tempo), não da métrica.

---

## 5. Propagação de contexto: entre serviços e entre threads

Um trace distribuído só existe se o contexto sobreviver a duas travessias hostis: a rede e o pool de threads.

### 5.1 Entre serviços: W3C `traceparent` de graça

O hello-service usa dois estilos de cliente HTTP — um [HTTP interface client declarativo](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/hello-service/src/main/java/com/example/hello/user/UserServiceHttpClient.java) (`@GetExchange`) para o user-service e um `RestClient` para o greeting-service. Ambos, **desde que construídos a partir do builder injetado pelo Boot**, saem instrumentados: cada chamada gera um span de cliente e injeta o header `traceparent` (W3C Trace Context).

É verificável em dois minutos com o projeto rodando. Uma única chamada `curl localhost:8080/api/1` produz nos logs dos **três** serviços o mesmo trace id no MDC:

```
hello-service    [a24f72c1907a996866b03485a03b312d-...] Dizendo olá para o usuário 1...
user-service     [a24f72c1907a996866b03485a03b312d-...] Buscando usuário com id 1
greeting-service [a24f72c1907a996866b03485a03b312d-...] Consultando saudação para o locale de
```

E o header que carregou o contexto aparece no log de headers do serviço downstream: `traceparent: 00-a24f72c1907a996866b03485a03b312d-c5be81b528ea843b-01`.

O projeto fecha o ciclo devolvendo o trace id ao chamador — o [AddTraceIdFilter](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/shared/src/main/java/com/example/shared/AddTraceIdFilter.java) do módulo shared:

```java
// Resposta HTTP ganha X-Trace-Id: o cliente (ou o time de suporte) pode abrir
// o trace exato no Grafana a partir do id que recebeu junto com o erro.
String traceId = getTraceId();
if (traceId != null) {
    response.setHeader("X-Trace-Id", traceId);
}
```

Em um fluxo de pagamento, esse header é a diferença entre "o cliente reclamou e vamos procurar nos logs por horário" e "o app capturou o `X-Trace-Id` da resposta 500 e o suporte abriu a timeline exata da transação".

### 5.2 Entre threads: a propriedade que evita traces órfãos

O hello-service tem um modo assíncrono (`hello.async=true`) em que user e greeting são consultados **em paralelo**, via `AsyncTaskExecutor`:

```java
public Future<User> findAsync(long id) {
    // A tarefa roda em OUTRA thread. Sem propagação de contexto,
    // o span criado lá dentro nasceria órfão — um trace novo, desconectado.
    return this.asyncTaskExecutor.submit(() -> findImpl(id));
}
```

O que mantém o trace íntegro é uma única linha de configuração:

```properties
spring.task.execution.propagate-context=true
```

Ela faz o Boot decorar o `applicationTaskExecutor` com a biblioteca `context-propagation` do Micrometer, que captura o contexto de observação na submissão e o restaura na execução. **Este é o esquecimento número um em orquestrações assíncronas** — o sintoma são spans de chamadas downstream aparecendo como traces separados no Tempo, e ninguém entende por quê.

---

## 6. Logs e métricas no mesmo trilho — e a ponte para a API pura do OTel

### 6.1 Logs via OTLP, não via scraping

Em vez de coletar arquivos de log, o projeto envia cada registro do Logback direto ao SDK OpenTelemetry — que o exporta via OTLP com trace id e span id anexados. O registro do appender é feito programaticamente no [InstallOpenTelemetryAppender](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/shared/src/main/java/com/example/shared/InstallOpenTelemetryAppender.java):

```java
@Override
public void afterPropertiesSet() {
    // Conecta o appender <OpenTelemetry> do logback-spring.xml
    // à instância de OpenTelemetry autoconfigurada pelo Boot.
    OpenTelemetryAppender.install(this.openTelemetry);
}
```

O resultado prático no Grafana: do log de erro no Loki, um clique leva ao trace no Tempo — a correlação vem no dado, não de convenção de parsing.

### 6.2 Métricas com convenções OTel

Métricas seguem via Micrometer → OTLP. O detalhe fino está no [OpenTelemetryConfiguration](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/shared/src/main/java/com/example/shared/OpenTelemetryConfiguration.java) do módulo shared: ele registra as convenções de nomenclatura OTel para métricas de JVM e HTTP server (`OpenTelemetryJvmMemoryMeterConventions`, `OpenTelemetryServerRequestObservationConvention` etc.), fazendo `jvm.memory.used` e `http.server.request.duration` saírem com os nomes das convenções semânticas do OpenTelemetry — e não com os nomes históricos do Micrometer. Se seus dashboards são compartilhados com serviços não-JVM, essa uniformidade paga o esforço.

### 6.3 Quando o código fala OTel puro

E se um componente for instrumentado direto com a API do OpenTelemetry — sem Micrometer? O projeto demonstra em [SomeOpenTelemetryApiInstrumentedComponent](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/hello-service/src/main/java/com/example/hello/SomeOpenTelemetryApiInstrumentedComponent.java):

```java
Span span = this.tracer.spanBuilder("dummy-span").startSpan();
try (Scope scope = span.makeCurrent()) {
    // Se chamado dentro de um fluxo iniciado pelo Micrometer (@Observed),
    // este span entra como FILHO no trace corrente — o contexto do
    // Micrometer é propagado de forma transparente para o OTel.
    ...
} finally {
    span.end();
}
```

Há uma pegadinha assimétrica: **traces interoperam de graça, métricas não**. O `Meter` da API OTel não passa pelo Micrometer; para que um `LongCounter` OTel chegue ao backend, o projeto monta um `SdkMeterProvider` com `PeriodicMetricReader` + `OtlpHttpMetricExporter` próprios ([OpenTelemetryMetricsConfiguration](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/hello-service/src/main/java/com/example/hello/OpenTelemetryMetricsConfiguration.java)). Se seu time mistura as duas APIs de métrica, esse wiring extra é o custo — padronize em uma.

---

## 7. Rodando: do `docker compose up` ao trace com erro

```bash
# 1. Stack Grafana LGTM (UI :3000, OTLP gRPC :4317, OTLP HTTP :4318)
docker compose up -d

# 2. Os três serviços (Linux/macOS; no Windows: .\start-services.ps1)
./start-services.sh

# 3. Tráfego
curl -i localhost:8080/api/1                          # Olá Moritz  (repare no X-Trace-Id)
curl -i -H "Accept-Language: de" localhost:8080/api/2 # Hallo Andy
curl -i localhost:8080/api/boom                       # 500 — trace com erro para explorar no Tempo
```

Em `http://localhost:3000` (sem login), os três sinais ficam nos apps de exploração do Grafana — logs (Loki), métricas (Mimir) e traces (Tempo). O trace do `/boom` mostra a exceção registrada no span; o trace do `/api/1` em modo assíncrono mostra user e greeting consultados em paralelo sob o mesmo pai.

Para quem quer apenas **inspecionar o OTLP cru** sem stack de visualização, o projeto inclui um compose alternativo com um OpenTelemetry Collector que imprime tudo no stdout — [otel-collector-compose.yaml](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/otel-collector-compose.yaml). É a ferramenta certa para depurar "o dado está saindo da aplicação?" isoladamente.

---

## 8. Telemetria também se testa

Instrumentação sem teste regride em silêncio: alguém renomeia uma observação, um dashboard quebra semanas depois, e ninguém liga uma coisa à outra. O projeto trata telemetria como comportamento testável, em camadas:

**Observações** — o `TestObservationRegistry` do Micrometer substitui o registry autoconfigurado e permite assertar nome e key values ([GreetingObservationTest](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/greeting-service/src/test/java/com/example/greeting/GreetingObservationTest.java)):

```java
assertThat(observationRegistry)
    .hasObservationWithNameEqualTo("greeting.get")
    .that()
    .hasHighCardinalityKeyValue("locale", "de");  // alta cardinalidade — ver seção 4.1
```

**Spans** — um `InMemorySpanExporter` registrado como bean `SpanProcessor` adicional captura os spans reais; o Boot agrega todos os `SpanProcessor` do contexto ao tracer provider. Testes verificam que o span existe, com atributos e hierarquia pai→filho corretos dentro da requisição ([GreetingTracePropagationTest](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/greeting-service/src/test/java/com/example/greeting/GreetingTracePropagationTest.java)).

**Orquestração** — testes de integração com WireMock 3.9.2 stubam user e greeting nas portas reais e validam, nos modos síncrono **e** assíncrono, que o `Accept-Language` é repassado e que o 404 downstream vira `UserNotFoundException` → 404 ([AbstractHelloServiceIntegrationTest](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/hello-service/src/test/java/com/example/hello/AbstractHelloServiceIntegrationTest.java)).

**Ponta a ponta** — um [EndToEndTest](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/hello-service/src/test/java/com/example/hello/EndToEndTest.java), desabilitado por padrão (`-De2e=true`), martela os endpoints em ciclos de 10 segundos contra os serviços vivos, validando status, corpo e a presença do `X-Trace-Id` — e de quebra gera tráfego contínuo para popular o Grafana em demonstrações.

Uma limitação honesta, descoberta na prática: o harness `@SpringBootTest` com os starters de teste **não conecta a extração do `traceparent` de entrada** da mesma forma que a configuração de produção — testar propagação *entre processos* exige os serviços reais (ou o E2E). Saber onde o harness diverge do runtime evita tanto falsos negativos quanto falsa confiança.

---

## 9. Anti-patterns e armadilhas

1. **`sampling.probability=1.0` em produção.** O projeto usa 1.0 por ser demo. Em produção, amostragem total significa custo de rede, CPU e armazenamento proporcionais ao tráfego — e o Tempo cobra por isso. Mitigação: amostragem parent-based com ratio (ex.: `0.1`) e, se necessário, tail sampling no collector para reter 100% dos traces com erro.
2. **Id de cliente/conta como tag de métrica.** Cada valor novo cria uma série temporal nova. Mitigação: alta cardinalidade só em span (é o default do `@ObservationKeyValue` — não o "corrija").
3. **Instanciar `RestClient`/`WebClient` manualmente.** `RestClient.builder().build()` fora do builder injetado nasce **sem** instrumentação: sem span de cliente, sem `traceparent`, trace quebrado dali para frente. O projeto documenta isso em comentário no próprio código ([HttpFacade](https://github.com/cleitonferreira/spring-boot-opentelemetry/blob/main/hello-service/src/main/java/com/example/hello/greeting/HttpFacade.java)). Mitigação: sempre parta do `RestClient.Builder` do contexto.
4. **Async sem `propagate-context`.** Sintoma clássico: chamadas paralelas aparecem como traces independentes. Mitigação: `spring.task.execution.propagate-context=true` — e um teste de propagação para não regredir.
5. **Java-agent + starters no mesmo processo.** Spans duplicados para cada requisição HTTP, métricas duplicadas com nomes divergentes. Escolha uma rota por processo.
6. **`export.step` agressivo por padrão.** O demo usa 10s (e 1s no hello-service) para feedback rápido. Em produção, o step padrão de 60s costuma bastar; steps curtos multiplicam volume no backend de métricas sem ganho analítico.
7. **Observabilidade fragmentada por backend proprietário.** Exportar cada sinal para uma ferramenta diferente sem correlação de trace id inviabiliza o debugging cross-sinal. O OTLP existe exatamente para manter a aplicação agnóstica: trocar Grafana LGTM por outro backend é mudança de endpoint, não de código.

---

## 10. Quando adotar, quando evitar, e a segunda-feira

**Adote a instrumentação nativa** se seus serviços são Spring Boot 3.x/4.x e você controla o código: o custo é um punhado de starters e propriedades, e o retorno é telemetria testável, sem agente para gerenciar em cada deploy, alinhada às convenções semânticas do OTel.

**Fique com o java-agent** onde não há alternativa: aplicações legadas congeladas, JVMs de terceiros, ou quando a organização padroniza o agente por política de plataforma — nesse caso, desligue a instrumentação nativa para não duplicar sinais.

**Evite over-engineering**: se você tem um monólito e um time pequeno, comece com os starters, sampling moderado e o LGTM local para aprender o fluxo — collector com pipelines elaborados, tail sampling e multi-backend vêm depois, puxados por necessidade.

Na segunda-feira: clone o [spring-boot-opentelemetry](https://github.com/cleitonferreira/spring-boot-opentelemetry), rode `docker compose up -d` e `./start-services.sh`, dispare `curl localhost:8080/api/boom` e abra o trace do erro no Grafana. Depois replique no seu serviço: starters, `@Observed` no primeiro caso de uso crítico, `propagate-context` se houver async, e um teste com `TestObservationRegistry` antes do primeiro dashboard.

---

## Checklist para implementação em produção

**Dependências e build**

- [ ] Starters modulares corretos para o Boot 4 (`-opentelemetry`, `-micrometer-metrics`, `-aspectj` para `@Observed`)
- [ ] Versão GA do Spring Boot (milestones só em laboratório)
- [ ] Flag `--sun-misc-unsafe-memory-access=allow` avaliada para JDK 24+ (JEP 498, via protobuf do exporter OTLP)
- [ ] Uma única rota de instrumentação por processo (nativa **ou** java-agent, nunca ambos)

**Instrumentação**

- [ ] `management.observations.annotations.enabled=true` e casos de uso críticos anotados com `@Observed`
- [ ] Convenção de cardinalidade documentada: enumeráveis em `lowCardinality`, identificadores em `highCardinality`
- [ ] Clientes HTTP sempre criados a partir do builder injetado (nunca `RestClient.builder()` manual)
- [ ] `spring.task.execution.propagate-context=true` onde houver `@Async`/executors
- [ ] Header `X-Trace-Id` (ou equivalente) devolvido nas respostas para correlação com suporte

**Export e custo**

- [ ] Endpoints OTLP explícitos por ambiente (`management.opentelemetry.*`, `management.otlp.metrics.export.url`)
- [ ] `sampling.probability` < 1.0 com estratégia definida (parent-based; tail sampling no collector se necessário)
- [ ] `export.step` de métricas ≥ 60s, salvo justificativa
- [ ] Volume de telemetria estimado e custo do backend calculado antes do go-live

**Testes e operação**

- [ ] Testes de observação (`TestObservationRegistry`) cobrindo nomes e key values dos `@Observed` críticos
- [ ] Teste de spans com `InMemorySpanExporter` para hierarquia e atributos
- [ ] Propagação entre serviços validada em ambiente real (o harness de teste não cobre a extração W3C de entrada)
- [ ] Dashboards e alertas construídos sobre métricas (SLO) com drill-down para traces (diagnóstico)

---

*Referências primárias: documentação oficial do Spring Boot (seções Observability, OpenTelemetry e Micrometer Metrics em docs.spring.io/spring-boot), documentação do Micrometer Observation e do micrometer-tracing (micrometer.io/docs), documentação do OpenTelemetry Java e da especificação OTLP/W3C Trace Context (opentelemetry.io/docs e w3.org/TR/trace-context), repositório opentelemetry-java-instrumentation (appender Logback 2.25.0-alpha), imagem grafana/otel-lgtm (github.com/grafana/docker-otel-lgtm) e o código-fonte completo do projeto de referência em [github.com/cleitonferreira/spring-boot-opentelemetry](https://github.com/cleitonferreira/spring-boot-opentelemetry).*
