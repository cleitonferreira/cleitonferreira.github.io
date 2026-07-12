---
title: "JSpecify no Spring Framework 7: null safety como contrato de compilação"
description: >-
  Como o Spring Framework 7 adotou as anotações JSpecify e o que muda na prática:
  @NullMarked como default não-nulo, semântica TYPE_USE, enforcement com NullAway
  no build, comparação com Optional, exemplo completo em Spring Boot 4 e checklist de produção.
author: cleiton
date: 2026-07-12 09:00:00 -0300
categories: [Java, Spring Boot]
tags: [jspecify, null safety, spring framework, spring boot, java, nullaway]
---

## 1. Resumo

O Spring Framework 7 (GA em novembro de 2025, base do Spring Boot 4) migrou todo o seu codebase para as anotações **JSpecify 1.0**, o padrão de nulidade apoiado por Google, JetBrains, Oracle, Broadcom, Uber, Meta e Sonar. As anotações antigas de `org.springframework.lang` (`@Nullable`, `@NonNull`, `@NonNullApi`, `@NonNullFields`) foram **depreciadas**. Na prática:

- Nulidade deixa de ser convenção documental e vira **contrato verificável em tempo de compilação**, via IDE (IntelliJ IDEA 2025.3+ com suporte de primeira classe) e via build (**NullAway** sobre Error Prone).
- Com `@NullMarked` no pacote, **não-nulo passa a ser o default** e apenas os pontos realmente nuláveis recebem `@Nullable` — inversão do modelo JSR 305, que exigia anotar tudo.
- As anotações JSpecify usam semântica **TYPE_USE**: a nulidade é expressa no *uso do tipo*, o que permite anotar genéricos (`List<@Nullable String>`), arrays e varargs — algo impossível no modelo anterior.
- Custo em runtime: **zero**. As anotações não geram bytecode de verificação; toda a checagem é estática. Isso posiciona JSpecify como alternativa a `Optional<T>` em assinaturas internas, sem overhead de alocação.
- O NPE não "acaba" por decreto: fronteiras de desserialização (Jackson), entidades JPA, injeção tardia de campos e bibliotecas de terceiros não anotadas (incluindo o AWS SDK) continuam sendo pontos cegos que exigem tratamento explícito.

Se seu time está migrando para Spring Boot 4, adotar `@NullMarked` + NullAway no CI é provavelmente o maior ganho de confiabilidade por hora de engenharia disponível hoje no ecossistema Java.

---

## 2. Contexto do problema

O `NullPointerException` continua sendo a exceção mais recorrente em produção no ecossistema JVM. Tony Hoare chamou a referência nula de "erro de um bilhão de dólares", mas o diagnóstico mais preciso — repetido pelo próprio time do Spring — é outro: o erro não foi inventar o `null`, e sim **não expressá-lo no sistema de tipos**. Em Java, `String` significa "uma string, ou talvez nada", e o compilador não distingue os dois casos.

As consequências de engenharia são conhecidas:

- **Programação defensiva difusa**: `if (x != null)` espalhado sem critério, porque ninguém sabe onde o null pode de fato ocorrer. Isso adiciona complexidade ciclomática e mascara bugs (o null "engolido" silenciosamente vira inconsistência de dados três camadas depois).
- **Contratos implícitos**: o Javadoc diz "may return null" — quando diz. O contrato vive na cabeça do autor original e morre no primeiro refactoring.
- **Custo de detecção tardia**: um NPE detectado em produção custa ordens de magnitude mais do que um warning no code review. Em sistemas financeiros, um NPE em um fluxo de liquidação ou de processamento de pagamento não é só um erro 500 — é reconciliação manual, incidente e post-mortem.

O ecossistema Java tentou resolver isso ao menos quatro vezes, e a fragmentação virou parte do problema: JSR 305 (`javax.annotation.Nullable`, dormante desde 2006, com problemas de split-package no JPMS), anotações do JetBrains (`org.jetbrains.annotations`), Checker Framework (`org.checkerframework`), Eclipse JDT (`org.eclipse.jdt.annotation`) e as próprias anotações do Spring 5/6 (`org.springframework.lang`). Cada uma com semântica ligeiramente diferente, targets diferentes e suporte de ferramenta diferente. Um projeto típico misturava duas ou três delas sem perceber.

O JSpecify nasceu em 2018 exatamente para encerrar essa fragmentação: um grupo de trabalho neutro (Google, JetBrains, Oracle, Broadcom/Spring, Uber, Meta, Sonar) produzindo **uma especificação formal de semântica de nulidade**, não apenas mais um jar de anotações. A versão 1.0 saiu em julho de 2024 com garantia de compatibilidade retroativa. O Spring Framework 7 é o primeiro grande framework a adotá-la de ponta a ponta — seguido por JUnit 6, Guava 33.4+ e, progressivamente, todo o portfólio Spring (Data, Security, Integration, Batch, Kafka).

A mudança relevante para quem opera sistemas: **as APIs do Spring que você chama todos os dias agora declaram formalmente onde podem retornar null**, e seu tooling passa a cobrar isso de você.

---

## 3. Fundamentos técnicos necessários

### 3.1 As quatro anotações

O JSpecify define exatamente quatro anotações no pacote `org.jspecify.annotations`:

| Anotação | Escopo | Semântica |
|---|---|---|
| `@Nullable` | Uso de tipo | Este uso de tipo **pode** conter null |
| `@NonNull` | Uso de tipo | Este uso de tipo **nunca** contém null |
| `@NullMarked` | Módulo, pacote, classe, método | Dentro deste escopo, todo tipo não anotado é **não-nulo por default** |
| `@NullUnmarked` | Pacote, classe, método | Reverte para o estado "nulidade não especificada" (escape hatch para migração) |

O modelo de três estados é o que importa entender: um tipo pode ser **não-nulo**, **nulável** ou **não especificado** (unspecified). Código legado sem anotações fica em "não especificado" — as ferramentas não reclamam, mas também não protegem. `@NullMarked` elimina o terceiro estado dentro do seu escopo.

### 3.2 TYPE_USE: a diferença estrutural em relação ao JSR 305

As anotações do Spring 5/6 (semântica JSR 305) tinham target de **declaração**: aplicavam-se a parâmetros, retornos e campos como elementos. As anotações JSpecify têm target `ElementType.TYPE_USE`: aplicam-se ao **uso do tipo em si**. A diferença parece sutil e é enorme na prática:

```java
// Impossível de expressar com JSR 305 / org.springframework.lang:

// Lista não-nula de elementos que podem ser null
List<@Nullable String> valores;

// Array não-nulo de elementos não-nulos vs.
// array nulável de elementos não-nulos
String[] a;              // dentro de @NullMarked: array e elementos não-nulos
String @Nullable [] b;   // o array pode ser null, os elementos não
@Nullable String[] c;    // o array não pode ser null, os elementos podem

// Genéricos em assinaturas de API
<T extends @Nullable Object> T processa(T input);
```

Isso significa que a posição da anotação muda: em JSpecify, `@Nullable` vem imediatamente antes do tipo (`public @Nullable User findById(...)`), não antes do método. Ferramentas de migração (recipes do OpenRewrite) fazem essa conversão automaticamente.

### 3.3 O que mudou no Spring Framework 7

Três coisas concretas:

1. **Todo o codebase do Spring está anotado e verificado com NullAway no próprio build do framework.** Métodos como `Environment.getProperty(String)` agora retornam `@Nullable String`; `RestClient`'s `body()` retorna `@Nullable T`. Antes, o contrato existia só em Javadoc.
2. **`org.springframework.lang.*` está deprecated.** A recomendação oficial é migrar para JSpecify; a documentação do Spring recomenda o mesmo para qualquer biblioteca do ecossistema (Reactor, Micrometer, projetos da comunidade).
3. **Interoperabilidade Kotlin nativa.** Com Kotlin 2.x (baseline do Spring 7), as anotações JSpecify são traduzidas automaticamente para o sistema de nulidade do Kotlin — fim dos platform types (`String!`) ao consumir APIs Spring. Em Kotlin, violar o contrato vira **erro de compilação**, não warning.

Há ainda uma API de runtime (`org.springframework.core.Nullness`) para introspecção de nulidade via reflection — útil para autores de frameworks e bibliotecas de binding, irrelevante para código de aplicação típico.

### 3.4 A cadeia de enforcement

As anotações sozinhas não fazem nada. O valor vem da cadeia completa:

```
JSpecify (especificação + anotações)
   → IDE (IntelliJ 2025.3+: warnings inline, quick-fixes, data-flow analysis)
   → Build (Error Prone + NullAway: warning ou erro de compilação)
   → CI (build quebra; código null-unsafe não chega em produção)
```

O NullAway (projeto da Uber, mantido ativamente) roda como plugin do Error Prone e verifica o código durante a compilação com overhead pequeno de build. Requisitos práticos: **JDK 21+ para o NullAway em modo padrão**; o modo `JSpecifyMode=true` (checagem completa de genéricos, arrays e varargs) requer **JDK 22+** e ainda está em maturação — a recomendação oficial é ativá-lo como segundo passo, depois que o codebase compila limpo no modo padrão.

---

## 4. Soluções e abordagens

Há duas estratégias arquiteturais legítimas para expressar ausência de valor em Java hoje. Elas não são mutuamente exclusivas, mas competem em cada ponto de decisão de API.

### Abordagem 1 — Nulidade explícita com JSpecify + enforcement estático

A ideia: manter `null` como representação de ausência, mas torná-lo **visível no sistema de tipos via anotações** e **impossível de ignorar via tooling**.

Estrutura típica em um serviço Spring Boot 4:

```java
// src/main/java/br/com/exemplo/pagamentos/package-info.java
@NullMarked
package br.com.exemplo.pagamentos;

import org.jspecify.annotations.NullMarked;
```

```java
package br.com.exemplo.pagamentos;

import org.jspecify.annotations.Nullable;

// Dentro do pacote @NullMarked: tudo é não-nulo por default.
public interface CartaoTokenizer {

    // Único ponto nulável, explicitamente declarado no tipo de retorno:
    @Nullable String extrairToken(String authorizationHeader);

    // Contrato: nunca recebe null, nunca retorna null.
    // Nenhuma anotação necessária.
    String tokenizar(String pan);
}
```

Quem consome `extrairToken` e desreferencia o retorno sem checagem recebe warning no IDE e **falha de build** com NullAway configurado como `error`.

**Prós:**
- Custo de runtime **zero**: anotações não alocam, não geram branches, não aparecem em flame graphs. Em serviços de alta vazão (o time do Spring cita explicitamente esse ponto ao comparar com `Optional`), é abstração de custo zero até o Valhalla chegar.
- Compatível com APIs existentes: anotar não quebra assinatura binária nem exige refatoração de chamadores.
- Cobre **parâmetros, campos e genéricos** — lugares onde `Optional` é anti-pattern ou simplesmente não funciona.
- Verificação *shift-left*: o erro aparece no editor, segundos depois de escrito.
- Kotlin de graça: o mesmo contrato vale nos dois idiomas do time.

**Contras:**
- A garantia é **tão forte quanto o enforcement**. Anotações sem NullAway/IDE são documentação decorativa — e documentação decorativa envelhece mal.
- Fronteiras não anotadas (reflection, desserialização, bibliotecas legadas) escapam da análise. O NullAway assume, por design, que o que entra pela fronteira respeita os contratos declarados — se o Jackson materializar um campo `null` em um tipo não-nulo, o NPE volta.
- Exige disciplina de migração incremental em codebases grandes (daí `@NullUnmarked` existir).
- Curva pequena de aprendizado de semântica TYPE_USE (posição da anotação em arrays confunde no início).

### Abordagem 2 — Ausência como valor de domínio: `Optional<T>` (e tipos de resultado)

A ideia: eliminar `null` da API tornando a ausência um **valor de primeira classe**, via `Optional<T>` em retornos — ou, na variante mais rica, tipos de resultado próprios (`sealed interface Resultado permits Sucesso, NaoEncontrado, Falha`).

```java
public interface ContaRepository extends Repository<Conta, UUID> {
    // Idiomático em Spring Data desde sempre:
    Optional<Conta> findByDocumento(String documento);
}
```

**Prós:**
- Impossível "esquecer" a checagem: o tipo força o unwrap. Não depende de tooling externo.
- API fluente (`map`, `filter`, `orElseThrow`) expressa pipelines de transformação com clareza.
- Convenção já consolidada em Spring Data e no JDK (`Stream.findFirst`, etc.).
- Tipos de resultado sealed vão além da ausência: distinguem *por que* o valor não existe — algo que nem `null` nem `Optional` expressam.

**Contras:**
- **Overhead de runtime real**: cada `Optional.of/ofNullable` é uma alocação no heap. Em hot paths, isso pressiona o GC (escape analysis ajuda, mas não é garantia). O time do Spring cita esse custo como razão para não usar `Optional` internamente — pelo menos até value classes do Projeto Valhalla.
- **Não resolve parâmetros**: `Optional` como parâmetro é anti-pattern documentado (força `Optional.empty()` em todos os call sites, e o próprio `Optional` pode ser null — a ironia é completa).
- **Não resolve campos**: `Optional` não é `Serializable` e não foi projetado para estado.
- Quebra assinaturas existentes ao ser introduzido em API já publicada.
- Aumenta complexidade sintática em código que só precisava de um `if`.

---

## 5. Comparação técnica entre abordagens

| Dimensão | JSpecify + NullAway | `Optional<T>` |
|---|---|---|
| Custo de runtime | Zero (compile-time only) | Alocação por instância; pressão de GC em hot paths |
| Cobertura | Retornos, parâmetros, campos, genéricos, arrays, varargs | Apenas retornos (idiomático) |
| Garantia | Estática; depende de tooling configurado | Estrutural; garantida pelo compilador javac |
| Compatibilidade com API existente | Total (aditiva) | Quebra assinatura |
| Kotlin interop | Tradução automática para null safety nativa | `Optional` vira tipo opaco; unwrap manual |
| Expressividade de causa da ausência | Nenhuma (null é null) | Nenhuma (`empty` é `empty`); tipos sealed resolvem |
| Custo de migração em codebase grande | Incremental (`@NullMarked` pacote a pacote) | Invasivo (refatora todos os call sites) |
| Risco residual | Fronteiras não anotadas (Jackson, JPA, libs) | `Optional.get()` sem `isPresent` ainda lança NSEE |
| Manutenção | Contrato autoverificável a cada build | Contrato autoverificável, mas mais verboso |

**Síntese de decisão**: as duas abordagens ocupam camadas diferentes. JSpecify é o **substrato** — vale para 100% do código, custa zero e protege parâmetros e campos. `Optional` é uma **escolha pontual de design de API** para retornos onde a fluência do pipeline compensa a alocação (repositórios, lookups de baixa frequência). Em um serviço Spring Boot 4 bem estruturado, você usa os dois: `@NullMarked` em tudo, `Optional` onde o Spring Data já o tornou idiomático, e `@Nullable` nos retornos internos de alta frequência.

---

## 6. Exemplo prático com código: serviço de consulta de limites com Spring Boot 4 + DynamoDB

Cenário realista: um microserviço de análise de crédito que consulta limites pré-aprovados no DynamoDB e configurações no `Environment`. Duas fronteiras nuláveis clássicas: o SDK da AWS (não anotado com JSpecify) e propriedades de configuração.

### 6.1 Build (Maven)

```xml
<dependencies>
    <dependency>
        <groupId>org.jspecify</groupId>
        <artifactId>jspecify</artifactId>
        <version>1.0.0</version>
    </dependency>
</dependencies>

<build>
    <plugins>
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-compiler-plugin</artifactId>
            <configuration>
                <release>21</release>
                <compilerArgs>
                    <arg>-XDcompilePolicy=simple</arg>
                    <arg>--should-stop=ifError=FLOW</arg>
                    <arg>-Xplugin:ErrorProne \
                         -XepDisableAllChecks \
                         -Xep:NullAway:ERROR \
                         -XepOpt:NullAway:OnlyNullMarked=true \
                         -XepOpt:NullAway:CustomContractAnnotations=org.springframework.lang.Contract</arg>
                </compilerArgs>
                <annotationProcessorPaths>
                    <path>
                        <groupId>com.google.errorprone</groupId>
                        <artifactId>error_prone_core</artifactId>
                        <version>2.41.0</version>
                    </path>
                    <path>
                        <groupId>com.uber.nullaway</groupId>
                        <artifactId>nullaway</artifactId>
                        <version>0.12.10</version>
                    </path>
                </annotationProcessorPaths>
            </configuration>
        </plugin>
    </plugins>
</build>
```

Pontos de atenção: `OnlyNullMarked=true` faz o NullAway analisar **apenas** o código dentro de escopos `@NullMarked` — é o que viabiliza migração incremental. `NullAway:ERROR` quebra o build em violação; comece com `WARN` durante a migração e promova a `ERROR` pacote a pacote.

### 6.2 O código

```java
// package-info.java
@NullMarked
package br.com.exemplo.credito;

import org.jspecify.annotations.NullMarked;
```

```java
package br.com.exemplo.credito;

import java.math.BigDecimal;
import java.util.Map;
import org.jspecify.annotations.Nullable;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;

@Service
public class LimiteService {

    private final DynamoDbClient dynamoDb;
    private final String tabela;

    public LimiteService(DynamoDbClient dynamoDb, Environment env) {
        this.dynamoDb = dynamoDb;

        // FRONTEIRA 1: Spring 7 declara getProperty como @Nullable String.
        // Desreferenciar direto = erro de build com NullAway.
        // Tratamento: fail-fast na construção do bean.
        String tabelaConfigurada = env.getProperty("credito.dynamodb.tabela");
        if (tabelaConfigurada == null) {
            throw new IllegalStateException(
                "Propriedade obrigatória ausente: credito.dynamodb.tabela");
        }
        this.tabela = tabelaConfigurada;
    }

    /**
     * Retorna o limite pré-aprovado, ou null se o cliente não tem oferta.
     * O contrato está no TIPO, não no Javadoc.
     */
    public @Nullable BigDecimal limitePreAprovado(String documento) {
        // FRONTEIRA 2: o AWS SDK v2 não é anotado com JSpecify.
        // Para o NullAway, os retornos são "unspecified" — a análise
        // não protege aqui. A responsabilidade de sanitizar é nossa.
        var response = dynamoDb.getItem(GetItemRequest.builder()
                .tableName(tabela)
                .key(Map.of("documento", AttributeValue.fromS(documento)))
                .build());

        if (!response.hasItem()) {
            return null; // legal: o retorno é declarado @Nullable
        }

        AttributeValue valor = response.item().get("limite");
        if (valor == null || valor.n() == null) {
            // Item existe mas sem o atributo — dado inconsistente na
            // fronteira. Sanitizamos ANTES de o valor entrar no domínio.
            return null;
        }
        return new BigDecimal(valor.n());
    }

    /**
     * Nenhuma anotação: dentro de @NullMarked, parâmetro e retorno
     * são não-nulos por contrato. Passar null aqui é erro de build
     * de quem chama.
     */
    public BigDecimal limiteEfetivo(String documento, BigDecimal rendaMensal) {
        BigDecimal preAprovado = limitePreAprovado(documento);

        // Se remover este if e usar preAprovado direto,
        // o NullAway falha a compilação:
        // "dereferenced expression preAprovado is @Nullable"
        if (preAprovado == null) {
            return rendaMensal.multiply(new BigDecimal("0.30"));
        }
        return preAprovado.min(rendaMensal.multiply(new BigDecimal("3")));
    }
}
```

```java
// Controller: a fronteira HTTP converte ausência em semântica de protocolo.
@RestController
@RequestMapping("/limites")
public class LimiteController {

    private final LimiteService service;

    public LimiteController(LimiteService service) {
        this.service = service;
    }

    @GetMapping("/{documento}")
    public ResponseEntity<LimiteResponse> consultar(@PathVariable String documento) {
        BigDecimal limite = service.limitePreAprovado(documento);
        if (limite == null) {
            return ResponseEntity.notFound().build(); // null → 404, explícito
        }
        return ResponseEntity.ok(new LimiteResponse(documento, limite));
    }
}
```

O que este exemplo demonstra na prática:

1. **O contrato do Spring trabalha para você**: `env.getProperty` retornando `@Nullable String` transforma um NPE de startup intermitente (a propriedade faltava só no ambiente de homologação) em erro de compilação que força a decisão fail-fast.
2. **Fronteiras não anotadas são explícitas na arquitetura**: o bloco que toca o AWS SDK sanitiza tudo antes de devolver ao domínio. Esse é o padrão *anti-corruption layer* aplicado à nulidade — dentro do `@NullMarked`, o mundo é seguro; a sujeira fica confinada na borda.
3. **Zero anotações no caminho feliz**: `limiteEfetivo` não tem uma anotação sequer e ainda assim carrega contrato total. Compare com o modelo Spring 5/6, onde seria preciso `@NonNull` em cada parâmetro ou `@NonNullApi` com semântica mais fraca.

---

## 7. Erros comuns e anti-patterns

**1. Anotar sem enforçar.** `@NullMarked` sem NullAway no CI e sem IDE atualizado é teatro de segurança. Pior: cria falsa confiança ("está anotado, então é seguro"). A anotação é a declaração; o checker é a garantia.

**2. Confiar no contrato em fronteiras de desserialização.** Jackson materializa objetos por reflection e ignora completamente as anotações de nulidade. Um payload sem o campo `documento` produz um record com `documento == null` mesmo dentro de `@NullMarked`. Mitigação: Bean Validation (`@NotNull` do Jakarta Validation — que é validação de *runtime*, papel diferente do JSpecify) na fronteira HTTP, ou validação explícita no construtor compacto do record.

**3. Confundir JSpecify `@NonNull` com Jakarta `@NotNull`.** O primeiro é contrato estático para o compilador/analisador; o segundo é validação de runtime executada pelo Hibernate Validator. Eles são complementares — JSpecify dentro do código, `@NotNull` nas bordas — e usá-los como sinônimos deixa exatamente uma das duas camadas descoberta.

**4. `@SuppressWarnings("NullAway")` como resposta padrão.** O supressor existe para falsos positivos legítimos e documentados (ex.: `@SuppressWarnings("NullAway.Init")` para campos com inicialização tardia via `InitializingBean` ou `@PostConstruct`). Usá-lo para "fazer o build passar" reintroduz o problema com uma camada de tinta por cima. Todo suppress deve vir com comentário justificando.

**5. Misturar bibliotecas de anotação.** `javax.annotation.Nullable` (JSR 305) + `org.jetbrains.annotations.Nullable` + JSpecify no mesmo módulo produz comportamento inconsistente entre ferramentas. Padronize com recipes do OpenRewrite e remova as dependências antigas do classpath.

**6. `Optional` em parâmetros e campos.** Anti-pattern clássico que a chegada do JSpecify torna injustificável: `@Nullable` no parâmetro expressa a mesma coisa sem alocação e sem poluir call sites.

**7. Anotar entidades JPA e esperar garantia.** Hibernate popula entidades por reflection; associações lazy não inicializadas e colunas nullable no schema não respeitam `@NullMarked`. O contrato de nulidade de uma entidade é o **schema do banco** — mantenha `NOT NULL` no DDL e as anotações coerentes com ele, mas trate a entidade como fronteira, não como domínio seguro.

**8. Ativar `JSpecifyMode` do NullAway de primeira.** O modo completo (genéricos, arrays, varargs) requer JDK 22+ e ainda está em desenvolvimento. A sequência recomendada é: modo padrão limpo primeiro, modo JSpecify depois.

---

## 8. Boas práticas recomendadas

- **`@NullMarked` no nível de pacote via `package-info.java`** (ou no `module-info.java`, se usar JPMS), nunca classe a classe. Granularidade fina gera inconsistência e esquecimento.
- **Migração incremental com ratchet**: comece com NullAway em `WARN` global, promova a `ERROR` por pacote conforme cada um zera warnings. `OnlyNullMarked=true` garante que código legado não bloqueie o build.
- **Sanitize nas bordas, confie no interior**: todo dado que entra por Jackson, JPA, AWS SDK, `Map.get`, cache ou reflection é suspeito até validação explícita. Depois disso, o interior `@NullMarked` dispensa checagens defensivas — e *remova* as checagens redundantes, porque `if (x != null)` sobre um tipo não-nulo é ruído que o próprio NullAway pode apontar.
- **Null nunca atravessa a fronteira HTTP como ambiguidade**: `@Nullable` no serviço vira `404`, `204` ou campo omitido no JSON, por decisão explícita no controller.
- **Priorize a atualização do tooling**: IntelliJ IDEA 2025.3+ prefere JSpecify automaticamente quando está no classpath e gera as anotações via quick-fix. O ROI da migração depende do time ver os warnings em tempo real.
- **Bibliotecas internas primeiro**: se sua organização mantém libs compartilhadas (starters internos, SDKs de plataforma), anote-as antes das aplicações — é onde o contrato multiplica valor, exatamente como o Spring fez com o próprio framework.
- **Times poliglota Java/Kotlin**: trate JSpecify como obrigatório. O contrato anotado em Java vira erro de compilação em Kotlin sem custo adicional — é a forma mais barata de alinhar os dois mundos.
- **Registre a decisão em ADR**: "nulidade expressa via JSpecify; `Optional` restrito a retornos de repositório; validação de borda via Jakarta Validation" é uma decisão de arquitetura, e deve sobreviver à rotatividade do time.

---

## 9. Conclusão orientada a decisão

**Use JSpecify + NullAway (abordagem 1) como padrão em qualquer serviço Spring Boot 4.** O custo de adoção é baixo (uma dependência, configuração de compiler plugin, `package-info.java`), o custo de runtime é zero e o retorno é uma classe inteira de bugs movida de "incidente em produção" para "warning no editor". Para código novo, não há trade-off real — é a linha de base.

**Use `Optional` (abordagem 2) taticamente**: retornos de repositórios Spring Data (onde já é idiomático), APIs públicas de bibliotecas onde você quer forçar o unwrap sem depender do tooling do consumidor, e pipelines de transformação onde a fluência compensa a alocação. Evite em parâmetros, campos e hot paths.

**Use tipos sealed de resultado** quando a ausência tem múltiplas causas relevantes para o chamador (não encontrado vs. bloqueado vs. erro de integração) — nem null nem `Optional` carregam essa informação.

**Adie a adoção apenas se**: seu baseline é JDK < 21 (NullAway fica inviável no build, restando só o suporte de IDE), ou se você ainda está no Spring Boot 3 sem janela de migração — nesse caso, o Boot 3.5 tem suporte OSS até junho de 2026, e a migração de nulidade pode ser feita junto com o upgrade para o Boot 4, aproveitando as recipes de OpenRewrite para as duas coisas.

O título da seção de marketing seria "o fim do NullPointerException". A leitura de engenharia é mais precisa e mais útil: o Spring 7 move a nulidade de **problema de runtime descoberto em produção** para **conversa de design travada no code review e no build**. O NPE residual fica confinado às fronteiras com código não anotado — que agora são visíveis, mapeáveis e tratáveis como decisão de arquitetura, não como surpresa.

---

## Checklist para implementação em produção

**Pré-requisitos**
- [ ] JDK 21+ no build (22+ se pretende ativar `NullAway:JSpecifyMode` depois)
- [ ] Spring Boot 4 / Spring Framework 7 (ou, no mínimo, dependência `org.jspecify:jspecify:1.0.0` em projetos Boot 3 para preparar o terreno)
- [ ] IntelliJ IDEA 2025.3+ (ou Eclipse com configuração manual de nullability) padronizado no time

**Build e CI**
- [ ] Error Prone + NullAway configurados no `maven-compiler-plugin`/Gradle com `OnlyNullMarked=true`
- [ ] Severidade inicial `WARN`; plano de promoção a `ERROR` por pacote com prazo definido
- [ ] Build de CI tratando NullAway `ERROR` como bloqueante de merge
- [ ] Recipes OpenRewrite executadas para converter `org.springframework.lang.*` / JSR 305 / JetBrains → JSpecify
- [ ] Dependências de anotações legadas (`jsr305`, `annotations` do JetBrains) removidas ou excluídas do classpath de compilação

**Código**
- [ ] `@NullMarked` em `package-info.java` de todos os pacotes novos; migração incremental nos existentes
- [ ] Retornos genuinamente nuláveis anotados com `@Nullable` na posição TYPE_USE (antes do tipo)
- [ ] Zero `@SuppressWarnings("NullAway")` sem comentário justificando; `NullAway.Init` restrito a inicialização tardia legítima
- [ ] Checagens `!= null` redundantes removidas de dentro de escopos `@NullMarked`

**Fronteiras**
- [ ] DTOs de entrada validados com Jakarta Validation (`@NotNull`, `@Valid`) na camada HTTP/mensageria
- [ ] Camada de sanitização explícita para SDKs não anotados (AWS SDK, clients de terceiros): nenhum valor cruza para o domínio sem validação
- [ ] Entidades JPA com `NOT NULL` no DDL coerente com as anotações; entidades tratadas como fronteira, não como domínio seguro
- [ ] Respostas HTTP com semântica explícita para ausência (404/204/campo omitido) — null nunca vaza serializado por acidente

**Governança**
- [ ] ADR registrando a política de nulidade (JSpecify como padrão, escopo do `Optional`, tratamento de fronteiras)
- [ ] Métrica acompanhada: contagem de NPEs em produção (APM/logs) antes e depois da adoção, por serviço
- [ ] Bibliotecas internas compartilhadas anotadas antes das aplicações consumidoras

---

*Referências primárias: "Null Safety" na documentação de referência do Spring Framework 7, "Null Safety in Spring apps with JSpecify and NullAway" (blog oficial spring.io), especificação e user guide do JSpecify (jspecify.dev) e documentação do NullAway (repositório uber/NullAway no GitHub).*
