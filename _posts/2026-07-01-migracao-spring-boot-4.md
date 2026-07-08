---
title: "Migração Spring Boot 3.5 → 4.0 na prática: Jackson 3, fim do Undertow, Hibernate 7 e os novos defaults do Spring Security 7"
description: >-
  Guia técnico de migração do Spring Boot 3.5 para o 4.0: as quebras reais de
  Jackson 3, remoção do Undertow, Hibernate 7.1 e Spring Security 7, com duas
  estratégias (incremental vs. corte limpo), exemplos de código e checklist de produção.
author: cleiton
date: 2026-07-01 09:00:00 -0300
categories: [Java, Spring Boot]
tags: [spring boot, java, jackson, hibernate, spring security, migração]
---

## 1. Resumo

O Spring Boot 4.0 (GA em novembro de 2025) é a release mais disruptiva desde a migração `javax` → `jakarta` do Boot 3. O suporte OSS do Spring Boot 3.5 terminou em **30 de junho de 2026**: a partir dessa data, a linha 3.x deixa de receber patches de segurança da comunidade. Se seus serviços ainda estão em 3.x, você tem um problema de exposição a CVEs, não apenas uma dívida técnica.

Os pontos que realmente quebram aplicações reais:

- **Jackson 3** substitui o Jackson 2 como biblioteca JSON padrão. Group IDs e pacotes mudaram de `com.fasterxml.jackson` para `tools.jackson` (exceto as anotações), o `ObjectMapper` mutável dá lugar ao `JsonMapper` imutável, exceções passam a ser *unchecked* e vários defaults de serialização mudaram — o tipo de quebra que compila, roda e **produz resultado errado em silêncio**.
- **Undertow foi removido** como servidor embarcado. O baseline agora é Servlet 6.1 (Jakarta EE 11), que o Undertow não implementa. Não há shim de compatibilidade: ou Tomcat 11, ou Jetty.
- **Hibernate 7.1 / JPA 3.2** remove APIs legadas da `Session` depreciadas no Hibernate 6, renomeia o annotation processor (`hibernate-jpamodelgen` → `hibernate-processor`) e muda internals de locking (de `synchronized` para `ReentrantLock`), o que beneficia virtual threads mas pode alterar comportamento sob carga.
- **Spring Security 7** remove definitivamente `WebSecurityConfigurerAdapter` e `authorizeRequests()`, impõe o DSL de lambdas e endurece defaults de CSRF — APIs REST que dependiam de auto-configuração permissiva passam a devolver `403` em requisições mutantes sem mensagem de erro óbvia.
- Além disso: **modularização** do Boot em 70+ módulos com starters renomeados (`spring-boot-starter-web` → `spring-boot-starter-webmvc`), remoção do JUnit 4, remoção de `@MockBean`/`@SpyBean`, auto-configuração do `RestTemplate` removida e dezenas de propriedades renomeadas.

Existem duas estratégias viáveis: **migração incremental com pontes de compatibilidade** (`spring-boot-starter-classic`, `spring-boot-jackson2`, `spring.jackson.use-jackson2-defaults`) ou **corte limpo com OpenRewrite** e refatoração direta. Este artigo detalha as duas, compara trade-offs e fecha com um exemplo prático completo e um checklist de produção.

---

## 2. Contexto do problema

O ciclo de releases do Spring segue um padrão previsível: major em novembro, minor em maio, e cada linha minor de Boot com ~13 meses de suporte OSS. O Spring Boot 4.0 foi lançado sobre o **Spring Framework 7** e o **Jakarta EE 11**, e o portfólio inteiro subiu de major na mesma janela: Spring Security 7, Spring Data 2025.1, Hibernate 7.1, Micrometer 2, Tomcat 11. Isso significa que "migrar para o Boot 4" é, na prática, **executar várias migrações simultaneamente** — o BOM do Boot arrasta todo o grafo de dependências junto.

O gatilho de urgência é o calendário: com o fim do suporte OSS do 3.5 em junho de 2026, cada CVE novo no ecossistema (e 2026 já mostrou que eles continuam vindo, como os CVEs do Spring AI 1.x) deixa de gerar patch para quem está em 3.x. As opções são três:

1. Migrar para o Boot 4 (o caminho natural).
2. Contratar suporte estendido comercial (HeroDevs, Tanzu Spring, OpenLogic) como ponte temporal.
3. Aceitar o risco — o que, para o setor financeiro e qualquer ambiente regulado, geralmente não passa em auditoria.

A boa notícia de engenharia: **não há migração de namespace** desta vez. O `jakarta.*` já foi resolvido no Boot 3. A má notícia: a comunidade catalogou mais de uma centena de breaking changes distintos entre 3.5 e 4.0, e eles se distribuem em três categorias de severidade crescente:

| Categoria | Comportamento | Exemplo |
|---|---|---|
| **Não compila** | Falha ruidosa, fácil de encontrar | `WebSecurityConfigurerAdapter` removido, Undertow removido, imports Jackson |
| **Não roda** | Build verde, falha no startup/runtime | Auto-config do `RestTemplate` removida, `@MockBean` removido, `javax.annotation` não reconhecido |
| **Resultado errado** | Build verde, startup ok, comportamento diferente | Defaults de serialização de datas do Jackson, CSRF do Security 7, `PropertyMapper` ignorando nulls |

A terceira categoria é a que justifica planejamento real em vez de um "sobe a versão e roda a suíte". É nela que este guia se concentra.

---

## 3. Fundamentos técnicos necessários

### 3.1 Baselines de plataforma

| Componente | Boot 3.5 | Boot 4.0 |
|---|---|---|
| Java | 17+ | **17+** (Java 25 com suporte de primeira classe; virtual threads exigem 21+) |
| Jakarta EE | 10 | **11** (Servlet 6.1, JPA 3.2, Bean Validation 3.1) |
| Spring Framework | 6.2 | **7.0** |
| Kotlin | 1.7+ | **2.2+** |
| Gradle | 7.6+ | **8.14+ / 9.x** |
| GraalVM (native) | 22.3+ | **25** |
| Jackson | 2.x | **3.x** (2.x opcional via módulo deprecado) |
| Hibernate | 6.6 | **7.1** |
| Tomcat | 10.1 | **11** |

Nota importante: o baseline de Java **permanece 17** — informação frequentemente errada em artigos de terceiros. Porém, os ganhos de performance mais relevantes do Boot 4 (virtual threads first-class, integração Loom-friendly do Hibernate 7) só existem em Java 21+. Se sua infraestrutura de CI/CD e imagens Docker ainda está em 17, o upgrade funciona, mas você está pagando o custo da migração sem colher o benefício de throughput. Decisão de arquitetura recomendada: **subir para Java 21 (ou 25) na mesma janela de migração**, aproveitando que o pipeline já será tocado.

### 3.2 Modularização: a mudança estrutural silenciosa

O Boot 4 fragmentou o monólito `spring-boot-autoconfigure` em mais de 70 módulos focados, cada um sob seu próprio pacote `org.springframework.boot.<module>`. Consequências práticas:

- **Starters renomeados.** `spring-boot-starter-web` vira `spring-boot-starter-webmvc`. Os nomes antigos continuam funcionando, mas estão deprecados e serão removidos.
- **Classpath menor por padrão.** Você passa a puxar apenas a auto-configuração do que realmente usa. Isso reduz tempo de startup (menos scanning e menos avaliações de `@ConditionalOnClass`), acelera compilação AOT e encolhe binários nativos GraalVM — relevante para cold start em Kubernetes e serverless.
- **Bibliotecas internas quebram.** Se você tem libs corporativas compartilhadas que tocam APIs internas do Boot, os pacotes mudaram. E o Spring desaconselha explicitamente suportar Boot 3 e Boot 4 no mesmo artefato — bibliotecas internas devem publicar artefatos separados por major.
- **Ponte de compatibilidade:** o `spring-boot-starter-classic` recria o classpath "gordo" do Boot 3, com todas as auto-configurações disponíveis. É uma muleta legítima para a primeira fase da migração, não um estado final.

### 3.3 O pré-requisito inegociável: passar pelo 3.5 limpo

Tudo que foi deprecado durante o ciclo 3.x foi **removido** no 4.0 — não soft-deprecated, removido. Migrar direto de 3.2 (ou pior, de 2.7) para 4.0 significa enfrentar erros de remoção e APIs novas ao mesmo tempo, o que transforma semanas em meses. O caminho correto:

1. Subir para o **último patch do 3.5.x**.
2. Zerar todos os warnings de deprecation (trate `-Werror` ou lint de deprecation como gate de CI nessa fase).
3. Só então trocar a versão do parent/BOM para 4.0.x.

---

## 4. As quatro quebras reais, em profundidade

### 4.1 Jackson 3: a quebra de maior superfície

Se sua aplicação serializa JSON (ela serializa), esta é a mudança que mais toca código. O Jackson 3 é um rebranding completo:

**Pacotes e coordenadas.** Tudo migra de `com.fasterxml.jackson.*` para `tools.jackson.*`, incluindo os group IDs Maven (`tools.jackson.core:jackson-core`). A **exceção deliberada são as anotações**: `@JsonProperty`, `@JsonFormat`, `@JsonView` etc. permanecem em `com.fasterxml.jackson.annotation`, compartilhadas entre Jackson 2 e 3. Isso é uma decisão de design inteligente do time do Jackson: seus modelos de domínio anotados funcionam com as duas versões, o que permite migração gradual em organizações com modelos compartilhados entre serviços.

```java
// Jackson 2 (Boot 3.x)
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.core.JsonProcessingException; // checked

// Jackson 3 (Boot 4.x)
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.core.JacksonException;               // unchecked
import com.fasterxml.jackson.annotation.JsonProperty;     // anotações NÃO mudam
```

**Imutabilidade.** O `ObjectMapper` do Jackson 2 era mutável — você podia (e muita gente fazia) alterar configuração depois de criado, uma fonte clássica de race conditions e de "configuração fantasma" em ambientes multi-thread. No Jackson 3, o `JsonMapper` é **imutável** e toda configuração acontece no builder:

```java
// Anti-pattern comum no Jackson 2 (mutação pós-construção):
ObjectMapper mapper = new ObjectMapper();
mapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS); // mutação!
mapper.registerModule(new JavaTimeModule());

// Jackson 3: configuração no builder, instância imutável e thread-safe:
JsonMapper mapper = JsonMapper.builder()
        .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
        .build();
// java.time, Optional e parameter-names já vêm embutidos — 
// jackson-datatype-jsr310 como módulo separado deixa de ser necessário.
```

**Exceções unchecked.** `JsonProcessingException` (checked) dá lugar a `JacksonException` (extends `RuntimeException`). Todo `try/catch` obrigatório em torno de `writeValueAsString` desaparece — e código em lambdas/streams que antes não compilava passa a funcionar direto. Cuidado: se você tinha handlers globais (`@ExceptionHandler`) capturando `JsonProcessingException`, eles precisam ser revisados.

**Defaults que mudaram (categoria "resultado errado"):**

- `WRITE_DATES_AS_TIMESTAMPS` agora é `false` — datas saem como ISO-8601, não como timestamps numéricos. Se algum consumidor da sua API parseia epoch millis, ele quebra.
- `FAIL_ON_TRAILING_TOKENS` agora é `true` — payloads com lixo após o JSON válido, antes aceitos, passam a falhar. Correto do ponto de vista de segurança, mas pode rejeitar inputs de clientes tolerados historicamente.
- **Descoberta automática de módulos:** o Boot 4 registra **todos** os módulos Jackson encontrados no classpath (no Boot 3, só os "well-known"). Um módulo transitivo que você nem sabia que existia pode alterar serialização. Desligável com `spring.jackson.find-and-add-modules=false`.

**Renomeações no lado Spring Boot:**

| Boot 3.x | Boot 4.x |
|---|---|
| `Jackson2ObjectMapperBuilderCustomizer` | `JsonMapperBuilderCustomizer` |
| `JsonObjectSerializer` | `ObjectValueSerializer` |
| `JsonValueDeserializer` | `ObjectValueDeserializer` |
| `spring.jackson.parser.*` | `spring.jackson.json.read.*` |

**Detalhe que derruba gente experiente:** o Boot 4 auto-configura mappers específicos por formato — um `JsonMapper` para JSON e um `XmlMapper` para XML. Para substituir o bean auto-configurado, **declarar um bean `ObjectMapper` não é mais suficiente**; declare um bean `JsonMapper`. Se sua configuração customizada "parou de ser aplicada" depois do upgrade, é quase certamente isso.

### 4.2 Remoção do Undertow: hard stop sem workaround

O Jakarta EE 11 eleva o baseline para **Servlet 6.1**, e o Undertow não implementa Servlet 6.1. Resultado: o starter e o suporte a Undertow como servidor embarcado foram completamente removidos. Não é deprecation — a aplicação **não sobe**.

Impactos de engenharia além do swap de dependência:

- **Propriedades não mapeiam 1:1.** `server.undertow.threads.worker`, buffer sizes e afins não têm equivalente direto em Tomcat. É preciso retraduzir a intenção (dimensionamento de pool, buffers) para o modelo do novo servidor:

```yaml
# Boot 3.x com Undertow — deixa de existir
server:
  undertow:
    threads:
      io: 4
      worker: 200
    buffer-size: 16384

# Boot 4.x com Tomcat 11 — retradução da intenção
server:
  tomcat:
    threads:
      max: 200
      min-spare: 10
    max-connections: 8192
    accept-count: 100
```

- **Perfil de performance muda.** O Undertow (XNIO) tinha características de I/O não-bloqueante e footprint de memória que motivaram sua escolha em muitos times. O Tomcat 11 fechou boa parte dessa distância, e — argumento decisivo em 2026 — com **virtual threads habilitadas** (`spring.threads.virtual.enabled=true` em Java 21+) o modelo "uma thread barata por requisição" torna a antiga vantagem do Undertow em concorrência amplamente irrelevante para a maioria dos workloads. Ainda assim: **refaça seus testes de carga**. Latência de cauda (p99) e comportamento sob saturação são diferentes entre servidores.
- **Ordem da migração:** troque o servidor **ainda no Boot 3.5**, valide em produção, e só depois suba para o 4.0. Isso isola a variável "servidor" da variável "framework" — princípio básico de mudar uma coisa por vez.

**Decisão Tomcat vs. Jetty:** Tomcat é o default, tem a maior base instalada e o melhor suporte da comunidade Spring; Jetty é preferível se você já tem expertise operacional nele ou requisitos específicos (por exemplo, tuning fino de HTTP/2). Na ausência de motivo forte, escolha Tomcat — menor atrito, mais documentação de troubleshooting.

### 4.3 Hibernate 7.1 e JPA 3.2

O Boot 4 gerencia Hibernate ORM 7.1 sobre Jakarta Persistence 3.2. As quebras:

**APIs legadas removidas.** Métodos da `Session` deprecados no Hibernate 6 (os sobreviventes da era `save()`/`update()`/`saveOrUpdate()`, além de variantes antigas de `load()`) foram removidos. Código que usa `EntityManager`/Spring Data puro raramente é afetado; código que faz `session.unwrap()` e usa API nativa do Hibernate precisa migrar para `persist()`/`merge()`/`getReference()`:

```java
// Hibernate 6 (deprecado) → não compila no Hibernate 7
session.save(entity);
session.update(entity);
Entity e = session.load(Entity.class, id);

// Hibernate 7
session.persist(entity);
Entity merged = session.merge(entity);
Entity ref = session.getReference(Entity.class, id); // proxy lazy
```

**Annotation processor renomeado.** `hibernate-jpamodelgen` foi substituído por `hibernate-processor`. Se você usa o metamodelo estático (`Entity_`) para Criteria API type-safe, o build quebra até ajustar a coordenada no `annotationProcessorPaths` do Maven ou no `annotationProcessor` do Gradle.

**Internals Loom-friendly.** O Hibernate 7 trocou blocos `synchronized` por `ReentrantLock` nos caminhos críticos. Em Java 21+ com virtual threads, isso elimina o *pinning* de carrier threads que penalizava aplicações database-heavy no Hibernate 6. Benchmarks da comunidade reportam ganhos significativos de throughput em queries derivadas do Spring Data (a nova compilação AOT de repositórios contribui aqui também). É o principal argumento de performance a favor da migração.

**SQL gerado pode mudar.** Como em todo major do Hibernate, o SQL emitido para certas construções (joins implícitos, paginação, funções de dialeto) pode variar sutilmente. Se você tem testes que asseram SQL literal, ou índices desenhados para o plano de execução do SQL antigo, valide com `hibernate.show_sql`/datasource-proxy em staging e compare planos de execução para as queries quentes.

**Spring Batch (efeito colateral do mesmo release train):** o `spring-boot-starter-batch` agora opera **em memória por padrão** — o Batch para de gravar metadados no seu banco silenciosamente após o upgrade. Se você depende de restartability/histórico de jobs, troque para `spring-boot-starter-batch-jdbc`. Este é um exemplo perfeito da categoria "compila, roda, resultado errado".

### 4.4 Spring Security 7: os defaults que devolvem 403

O Security 7 conclui a limpeza iniciada no 5.7/6.x:

- **`WebSecurityConfigurerAdapter` removido.** Se algum módulo legado ainda o estende, não compila. A substituição é o bean `SecurityFilterChain`.
- **`authorizeRequests()` removido** (junto com todo o DSL encadeado por `.and()`). Só existe o DSL de lambdas: `authorizeHttpRequests(auth -> ...)`.
- **CSRF endurecido.** A proteção CSRF passa a ser aplicada de forma mais agressiva por padrão, inclusive em endpoints de API que antes escapavam pela auto-configuração permissiva. O sintoma é insidioso: **todo POST/PUT/DELETE/PATCH devolve `403 Forbidden`**, sem stack trace, sem log óbvio. APIs stateless autenticadas por token devem desabilitar CSRF **explicitamente e conscientemente** — a decisão que antes era implícita agora precisa estar escrita no código, o que é uma melhoria de segurança real (CSRF só é irrelevante quando não há autenticação baseada em cookie/sessão).
- **OAuth2 password grant removido** — alinhado à OAuth 2.1, que aboliu o grant. Fluxos machine-to-machine devem usar `client_credentials`; fluxos de usuário, `authorization_code` + PKCE. Se você tem integrações legadas usando password grant, essa é uma migração de contrato com terceiros, não só de código.

```java
// Boot 3.x — ainda compilava (deprecado):
http.authorizeRequests()
    .antMatchers("/api/public/**").permitAll()
    .anyRequest().authenticated()
    .and()
    .csrf().disable();

// Boot 4.x / Security 7 — única forma válida:
@Bean
SecurityFilterChain apiSecurity(HttpSecurity http) throws Exception {
    http
        .authorizeHttpRequests(auth -> auth
            .requestMatchers("/api/public/**").permitAll()
            .requestMatchers("/actuator/health").permitAll()
            .anyRequest().authenticated()
        )
        // API stateless com JWT: CSRF não se aplica — decisão explícita e documentada
        .csrf(csrf -> csrf.disable())
        .sessionManagement(session -> 
            session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()));
    return http.build();
}
```

**No lado dos testes**, o mesmo release train remove `@MockBean`/`@SpyBean` (substituídos por `@MockitoBean`/`@MockitoSpyBean`) e o `MockitoTestExecutionListener` — se seus `@Mock`/`@Captor` pararam de funcionar, adote o `MockitoExtension` do próprio Mockito. O JUnit 4 saiu do classpath gerenciado: suítes com `@RunWith` precisam concluir a migração para JUnit 5 antes do upgrade.

---

## 5. Soluções e abordagens

Não existe uma única forma correta de executar essa migração. Há duas estratégias dominantes, com perfis de risco opostos.

### Abordagem 1 — Migração incremental com pontes de compatibilidade

A filosofia: **subir a versão primeiro, convergir depois**. O Boot 4 foi desenhado com "muletas" oficiais exatamente para isso:

1. `spring-boot-starter-classic` — recria o classpath monolítico do Boot 3, adiando a adoção dos starters modulares.
2. `spring-boot-jackson2` — mantém um `ObjectMapper` Jackson 2 funcional ao lado da auto-configuração Jackson 3 (propriedades sob `spring.jackson2.*`). **Deprecado desde o nascimento**, com remoção anunciada.
3. `spring.jackson.use-jackson2-defaults: true` — usa Jackson 3, mas com defaults alinhados ao comportamento do Jackson 2 no Boot 3 (datas como timestamp etc.), eliminando a categoria "resultado errado" do JSON durante a transição.
4. `spring-boot-properties-migrator` — analisa o environment no startup, aponta propriedades renomeadas/removidas e as traduz temporariamente em runtime.

```xml
<!-- Fase 1: sobe para 4.0 com o mínimo de refatoração -->
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.0.1</version>
</parent>

<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-classic</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-jackson2</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-properties-migrator</artifactId>
        <scope>runtime</scope>
    </dependency>
</dependencies>
```

```yaml
spring:
  jackson:
    use-jackson2-defaults: true   # remove depois de validar os defaults novos
```

Depois, em iterações separadas e individualmente testáveis: (a) starters modulares, (b) imports e APIs Jackson 3, (c) remoção do flag de defaults, (d) remoção do properties-migrator, (e) remoção do jackson2.

**Prós:** menor risco por deploy (cada mudança é pequena e reversível); serviços críticos saem da linha EOL rapidamente; contratos JSON preservados byte a byte na primeira fase; funciona bem para frotas grandes de microsserviços onde o gargalo é a coordenação, não o código.

**Contras:** a migração "termina duas vezes" — o custo total é maior; risco organizacional real de as pontes virarem permanentes (e elas **serão removidas** em releases futuras, transformando a muleta em bomba-relógio); o classpath clássico anula os ganhos de startup/nativo da modularização; convivência Jackson 2 + 3 no mesmo processo aumenta complexidade cognitiva (dois mappers, duas árvores de propriedades).

### Abordagem 2 — Corte limpo com OpenRewrite

A filosofia: **uma janela de migração concentrada, sem estado intermediário**. A mecânica bruta é automatizada por receitas OpenRewrite mantidas pela comunidade e pelo time Spring:

```bash
mvn -U org.openrewrite.maven:rewrite-maven-plugin:run \
  -Drewrite.recipeArtifactCoordinates=org.openrewrite.recipe:rewrite-spring:LATEST \
  -Drewrite.activeRecipes=org.openrewrite.java.spring.boot4.UpgradeSpringBoot_4_0
```

A receita cobre: bump de versões no build, renomeação de starters, migração de imports Jackson (`com.fasterxml.jackson.*` → `tools.jackson.*` onde aplicável), propriedades renomeadas e substituição de APIs deprecadas com equivalente mecânico. O que ela **não** cobre — e vira trabalho manual — é o núcleo semântico: lógica de `SecurityFilterChain` a partir de configurações exóticas, serializers customizados Jackson (a API de `JsonSerializer`/`ValueSerializer` mudou de contrato), tuning de servidor Undertow → Tomcat, e qualquer código que dependa de comportamento (não de assinatura).

**Prós:** custo total menor; estado final limpo desde o primeiro deploy pós-migração; colhe imediatamente os benefícios de performance (modularização, virtual threads, Hibernate 7); sem risco de "compat flags eternos"; a suíte de testes valida o estado final real, não um híbrido.

**Contras:** janela de risco concentrada — um deploy grande com muitas variáveis mudando juntas; exige cobertura de testes alta (especialmente testes de contrato JSON e de segurança) para ser responsável; em monólitos grandes, o branch de migração vive semanas e sofre com conflitos de merge contra o desenvolvimento normal; pressupõe que todas as dependências de terceiros já tenham versões compatíveis com Jakarta EE 11 e Jackson 3 — uma única lib incompatível trava tudo.

---

## 6. Comparação técnica entre abordagens

| Dimensão | Incremental (pontes) | Corte limpo (OpenRewrite) |
|---|---|---|
| **Risco por deploy** | Baixo — mudanças pequenas e reversíveis | Alto — muitas variáveis num deploy |
| **Risco acumulado** | Médio — pontes deprecadas podem virar permanentes | Baixo — sem estado intermediário |
| **Custo total de engenharia** | Maior (retrabalho, duas "conclusões") | Menor (uma passada) |
| **Time-to-EOL-safety** | Rápido — sai do 3.x em dias | Mais lento — sai do 3.x quando tudo estiver pronto |
| **Performance pós-migração** | Adiada (classpath clássico anula ganhos) | Imediata (modular + virtual threads + Hibernate 7) |
| **Exigência de cobertura de testes** | Moderada | Alta (é o mecanismo de segurança da abordagem) |
| **Adequação a frota de microsserviços** | Excelente (paraleliza por serviço) | Boa por serviço, cara em coordenação |
| **Adequação a monólito grande** | Boa (reduz blast radius) | Arriscada sem testes fortes |
| **Complexidade cognitiva durante a transição** | Alta (Jackson 2+3, dois modelos de config) | Baixa após o corte |
| **Compatibilidade de contratos JSON** | Preservada na fase 1 (`use-jackson2-defaults`) | Exige testes de contrato/golden files |

Na prática, a maioria dos times maduros usa um **híbrido**: OpenRewrite para a mecânica + `use-jackson2-defaults` como único flag de compatibilidade + prazo explícito (uma sprint, um trimestre) para removê-lo, tratado como item de backlog com dono.

---

## 7. Exemplo prático com código

Cenário realista: um serviço REST de contas (domínio bancário) em Boot 3.5 com Undertow, Jackson 2 customizado, JPA e segurança via JWT. Vamos ao antes/depois dos pontos nevrálgicos.

### 7.1 Build (Maven)

```xml
<!-- ANTES: Boot 3.5 -->
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.9</version>
</parent>
<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
        <exclusions>
            <exclusion>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-starter-tomcat</artifactId>
            </exclusion>
        </exclusions>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-undertow</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
        <groupId>org.hibernate.orm</groupId>
        <artifactId>hibernate-jpamodelgen</artifactId>
        <scope>provided</scope>
    </dependency>
</dependencies>
```

```xml
<!-- DEPOIS: Boot 4.0 -->
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.0.1</version>
</parent>
<dependencies>
    <!-- Starter renomeado; Undertow removido → Tomcat 11 (default do starter) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-webmvc</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <!-- jpamodelgen → processor -->
    <dependency>
        <groupId>org.hibernate.orm</groupId>
        <artifactId>hibernate-processor</artifactId>
        <scope>provided</scope>
    </dependency>
    <!-- Temporário, remover ao fim da migração -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-properties-migrator</artifactId>
        <scope>runtime</scope>
    </dependency>
</dependencies>
```

### 7.2 Configuração Jackson

```java
// ANTES (Boot 3.x / Jackson 2): customizer mutável
import com.fasterxml.jackson.databind.SerializationFeature;
import org.springframework.boot.autoconfigure.jackson.Jackson2ObjectMapperBuilderCustomizer;

@Configuration
public class JacksonConfig {

    @Bean
    Jackson2ObjectMapperBuilderCustomizer customizer() {
        return builder -> builder
                .featuresToDisable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
                .serializationInclusion(JsonInclude.Include.NON_NULL);
    }
}
```

```java
// DEPOIS (Boot 4.x / Jackson 3): customizer do JsonMapper imutável
import tools.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.annotation.JsonInclude;
import org.springframework.boot.jackson.autoconfigure.JsonMapperBuilderCustomizer;

@Configuration
public class JacksonConfig {

    @Bean
    JsonMapperBuilderCustomizer customizer() {
        // Datas ISO-8601 agora são o default do Jackson 3 — a linha sumiu.
        return builder -> builder
                .changeDefaultPropertyInclusion(incl ->
                        incl.withValueInclusion(JsonInclude.Include.NON_NULL));
    }
}
```

E um serializer customizado de valor monetário — exemplo do trabalho **manual** que o OpenRewrite não resolve:

```java
// DEPOIS: Jackson 3 — note o pacote e o contrato sem checked exception
import tools.jackson.core.JsonGenerator;
import tools.jackson.databind.SerializationContext;
import tools.jackson.databind.ser.std.StdSerializer;

public class MonetaryAmountSerializer extends StdSerializer<MonetaryAmount> {

    public MonetaryAmountSerializer() {
        super(MonetaryAmount.class);
    }

    @Override
    public void serialize(MonetaryAmount value, JsonGenerator gen,
                          SerializationContext ctxt) {
        gen.writeStartObject();
        gen.writeStringProperty("currency", value.currency().getCurrencyCode());
        gen.writeStringProperty("amount", value.amount().toPlainString());
        gen.writeEndObject();
    }
}
```

### 7.3 Uso do JsonMapper em serviço (exceções unchecked)

```java
// ANTES: checked exception forçava boilerplate e quebrava streams
public String toAuditPayload(TransferEvent event) {
    try {
        return objectMapper.writeValueAsString(event);
    } catch (JsonProcessingException e) {
        throw new AuditSerializationException(e);
    }
}

// DEPOIS: JacksonException é unchecked — o wrapper vira opcional
private final JsonMapper jsonMapper; // bean auto-configurado, injetável

public List<String> toAuditPayloads(List<TransferEvent> events) {
    return events.stream()
            .map(jsonMapper::writeValueAsString) // compila direto em lambda
            .toList();
}
```

### 7.4 Segurança

O `SecurityFilterChain` da seção 4.4 se aplica aqui integralmente. O ponto de validação prático: **escreva um teste que documente a decisão de CSRF**, para que o comportamento do Security 7 nunca mude por acidente debaixo de você:

```java
@SpringBootTest
@AutoConfigureMockMvc   // no Boot 4, esqueça esta anotação e o MockMvc virá null
class SecurityContractTest {

    @Autowired MockMvc mvc;

    @Test
    void postWithoutCsrfTokenSucceeds_becauseApiIsStatelessJwt() throws Exception {
        mvc.perform(post("/api/transfers")
                .with(jwt().authorities(new SimpleGrantedAuthority("SCOPE_transfers:write")))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"amount\":\"100.00\",\"currency\":\"BRL\"}"))
           .andExpect(status().isCreated()); // se voltar 403, o default mudou sob você
    }
}
```

### 7.5 Golden files para o contrato JSON

A defesa mais barata contra a categoria "resultado errado":

```java
@SpringBootTest
class SerializationContractTest {

    @Autowired JsonMapper jsonMapper;

    @Test
    void transferEventSerializationMatchesGoldenFile() throws Exception {
        var event = TestFixtures.transferEvent(); // datas, BigDecimal, enums, nulls
        String actual = jsonMapper.writeValueAsString(event);
        String golden = Files.readString(Path.of("src/test/resources/golden/transfer-event.json"));
        JSONAssert.assertEquals(golden, actual, JSONCompareMode.STRICT);
    }
}
```

Gere os golden files **antes** da migração, rodando no Boot 3.5. Qualquer divergência pós-upgrade é um breaking change de contrato detectado antes do canary — não pelo consumidor em produção.

---

## 8. Erros comuns e anti-patterns

- **Pular o 3.5.** Migrar de 3.2 → 4.0 direto mistura erros de remoção com APIs novas. O 3.5 limpo é o checkpoint obrigatório.
- **Tratar Jackson 3 como find-and-replace de imports.** A troca de pacote é a parte trivial. Defaults de serialização, imutabilidade do mapper, contrato novo de serializers customizados e module auto-discovery são mudanças **semânticas**.
- **Declarar bean `ObjectMapper` esperando substituir o mapper do Boot 4.** Não substitui mais. Declare `JsonMapper` (ou use `JsonMapperBuilderCustomizer`).
- **Desabilitar CSRF "porque deu 403".** O 403 é sintoma; a correção certa depende do modelo de autenticação. Desabilitar CSRF numa aplicação com sessão/cookie para "fazer funcionar" é reabrir uma vulnerabilidade clássica.
- **Compat flags sem data de morte.** `use-jackson2-defaults`, `spring-boot-jackson2`, `spring-boot-starter-classic` e o properties-migrator são pontes deprecadas. Rodar com eles "para sempre" significa fazer esta migração de novo, sob pressão, quando forem removidos.
- **Confiar no build verde.** Dezenas de mudanças do Boot 4 passam na compilação e falham em runtime ou — pior — produzem resultado diferente (Batch em memória, datas ISO, `PropertyMapper` pulando nulls). Build verde ≠ migração concluída.
- **Trocar Undertow e Boot na mesma release.** Duas variáveis grandes num deploy só. Servidor primeiro (ainda no 3.5), framework depois.
- **Copiar tuning de thread pool do Undertow para o Tomcat numericamente.** Os modelos de threading são diferentes; re-derive os números com teste de carga, ou melhor, avalie virtual threads e simplifique o tuning.
- **Ignorar bibliotecas internas compartilhadas.** Um jar corporativo compilado contra Boot 3 no classpath de um app Boot 4 é fonte de `NoClassDefFoundError` intermitente. Publique artefatos separados por major.
- **Asserts de SQL literal em testes.** Hibernate major novo = SQL potencialmente diferente. Teste comportamento (resultado, contagem de queries via datasource-proxy), não strings de SQL.

---

## 9. Boas práticas recomendadas

- **Inventário antes de código.** Rode `mvn dependency:tree` / `gradle dependencies` e classifique cada dependência: compatível com Jakarta EE 11 e Jackson 3? Tem versão para Spring Framework 7? Uma única lib travada define sua estratégia (incremental) antes de qualquer linha de código.
- **OpenRewrite para a mecânica, humanos para a semântica.** Automatize renomes de pacote, starters e propriedades; reserve o tempo do time para segurança, serializers e tuning de servidor.
- **Golden files de serialização + testes de contrato de segurança** como gate de CI durante toda a janela de migração. São os detectores da categoria "resultado errado".
- **Progressive delivery, não big-bang de tráfego.** Mesmo na abordagem de corte limpo, o *deploy* deve ser canary com error budget explícito, monitorando: taxa de erros de serialização, delta de 4xx/5xx (especialmente 403), falhas de autenticação e anomalias de queries/latência de banco.
- **Suba Java junto (17 → 21/25).** O custo marginal é pequeno na mesma janela e destrava virtual threads + os ganhos do Hibernate 7.
- **Trate as pontes como dívida com vencimento.** Cada flag de compatibilidade entra no backlog com dono e prazo. O "done" da migração é a remoção da última ponte, não o primeiro deploy no 4.0.
- **Um serviço piloto primeiro.** Numa frota de microsserviços, migre um serviço de criticidade média, documente as pedras no caminho num runbook interno e só então paralelize. O segundo serviço custa uma fração do primeiro.
- **Congele o contrato observável.** Antes de migrar, capture baselines: payloads JSON de endpoints críticos, headers de resposta, métricas de latência p50/p99, planos de execução das queries top-N. Comparar contra baseline é mais confiável do que "parece igual".

---

## 10. Conclusão orientada a decisão

**Use a abordagem incremental (pontes de compatibilidade) quando:**

- O prazo de EOL é o risco dominante e você precisa sair do 3.x rápido, com refatoração mínima.
- A frota é grande e heterogênea, e o custo de coordenação supera o custo de retrabalho.
- A cobertura de testes é fraca — as pontes reduzem a superfície de mudança comportamental por deploy enquanto você constrói a suíte que a abordagem 2 exige.
- Alguma dependência crítica ainda não suporta Jackson 3 (o `spring-boot-jackson2` existe exatamente para isso).

**Use o corte limpo (OpenRewrite + refatoração direta) quando:**

- A cobertura de testes é sólida, incluindo contratos de serialização e segurança.
- Você quer os ganhos de performance imediatamente: startup mais rápido pela modularização, throughput de banco do Hibernate 7 sob virtual threads, binários nativos menores.
- O serviço é novo ou pequeno o bastante para a janela de migração caber numa sprint.
- A cultura do time não sustenta dívidas com prazo — se flags deprecados tendem a virar permanentes na sua organização, não os introduza.

**Em qualquer cenário:** greenfield começa direto no Boot 4 (não há razão técnica para iniciar projeto novo em 3.x em 2026); quem está no Boot 2.x tem **duas** migrações e deve executá-las em sequência, nunca em um salto; e quem comprovadamente não consegue migrar antes de consumir o risco de CVEs deve orçar suporte estendido comercial como ponte — é um custo de seguro, não uma estratégia.

O Spring Boot 4 não é o upgrade traumático que o `javax` → `jakarta` foi, mas é o mais denso em mudanças comportamentais silenciosas da história recente do framework. A diferença entre uma migração de duas semanas e uma de três meses não está no volume de código alterado — está em ter tratado a categoria "compila, roda, resultado errado" com a seriedade de engenharia que ela exige.

---

## Checklist para implementação em produção

**Pré-migração**

- [ ] Atualizar para o último patch do Spring Boot 3.5.x e zerar todos os warnings de deprecation
- [ ] Inventariar dependências: compatibilidade com Jakarta EE 11 (Servlet 6.1 / JPA 3.2), Jackson 3 e Spring Framework 7
- [ ] Se usa Undertow: migrar para Tomcat 11 ou Jetty **ainda no 3.5** e validar em produção
- [ ] Concluir migração JUnit 4 → JUnit 5 e substituir `@MockBean`/`@SpyBean` → `@MockitoBean`/`@MockitoSpyBean`
- [ ] Gerar golden files dos payloads JSON críticos (datas, BigDecimal, enums, nulls, polimorfismo) no 3.5
- [ ] Capturar baselines: latência p50/p99, taxa de 4xx/5xx, planos de execução das queries quentes
- [ ] Validar CI/CD e imagens base: Java 17+ (recomendado 21/25), Gradle 8.14+/9, GraalVM 25 se usa native
- [ ] Definir estratégia (incremental vs. corte limpo) e registrar a decisão com prazo de remoção de cada ponte

**Migração**

- [ ] Rodar a receita OpenRewrite `UpgradeSpringBoot_4_0` e revisar o diff manualmente
- [ ] Trocar starters para os nomes modulares (`spring-boot-starter-webmvc` etc.) ou adotar `spring-boot-starter-classic` conscientemente
- [ ] Migrar imports Jackson (`tools.jackson.*`), customizers (`JsonMapperBuilderCustomizer`) e serializers customizados para o novo contrato
- [ ] Substituir beans `ObjectMapper` de override por beans `JsonMapper`
- [ ] Decidir explicitamente sobre `spring.jackson.use-jackson2-defaults` e `spring.jackson.find-and-add-modules`
- [ ] Reescrever configuração de segurança: `SecurityFilterChain` com DSL de lambdas; decisão de CSRF documentada e testada
- [ ] Trocar `hibernate-jpamodelgen` → `hibernate-processor`; migrar usos de API nativa da `Session` removidos
- [ ] Se usa Spring Batch com restartability: trocar para `spring-boot-starter-batch-jdbc`
- [ ] Adicionar `spring-boot-properties-migrator` (runtime) e corrigir todas as propriedades apontadas no startup
- [ ] Re-registrar `RestTemplate` manualmente se dependia da auto-configuração removida (ou migrar para `RestClient`)

**Validação e rollout**

- [ ] Suíte completa verde, incluindo testes de contrato JSON (golden files) e de segurança (CSRF/403)
- [ ] Teste de carga comparativo contra baseline (especialmente se trocou de servidor embarcado)
- [ ] Verificar logs de startup: zero warnings do properties-migrator, zero módulos Jackson inesperados
- [ ] Canary deploy com monitoramento de: erros de serialização, delta de 403/401, anomalias de SQL/latência de banco
- [ ] Habilitar e validar virtual threads (`spring.threads.virtual.enabled=true`) se em Java 21+, com teste de carga próprio

**Pós-migração**

- [ ] Remover `spring-boot-properties-migrator`
- [ ] Remover `use-jackson2-defaults`, `spring-boot-jackson2` e `spring-boot-starter-classic` dentro do prazo definido
- [ ] Atualizar runbooks de operação (tuning de Tomcat, novos endpoints/propriedades)
- [ ] Publicar runbook interno da migração antes de replicar nos demais serviços da frota
- [ ] Agendar acompanhamento do calendário de suporte do 4.x (próximo minor em maio; majors em novembro)

---

*Referências primárias: Spring Boot 4.0 Migration Guide (wiki oficial do projeto no GitHub), Spring Boot 4.0 Release Notes, "Introducing Jackson 3 support in Spring" (blog oficial spring.io), MIGRATING_TO_JACKSON_3.md (repositório FasterXML/jackson) e Spring Security 7 Migration Guide.*
