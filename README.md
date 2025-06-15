# Cleiton Ferreira - Site Pessoal

Este é o repositório do meu site pessoal, com informações sobre minha experiência profissional e artigos sobre REST APIs e outros tópicos técnicos.

## Estrutura do Site

- `index.htm`: Página principal do site
- `artigos/`: Diretório contendo os artigos do site
- `*.css`: Arquivos de estilo (base.css, grid.css, article.css)
- `*.js`: Scripts JavaScript para funcionalidades do site

## Sistema de Componentes

O site utiliza um sistema simples de componentes baseado em JavaScript para reutilizar elementos comuns em todas as páginas.

### Menu Lateral (Sidebar)

O arquivo `sidebar.js` contém o código para gerar dinamicamente o menu lateral com minhas informações profissionais. Este componente é usado em todas as páginas do site para manter a consistência e facilitar a manutenção.

#### Como usar o componente sidebar:

1. Adicione o link para o script `sidebar.js` no cabeçalho da página:
   ```html
   <script type="text/javascript" src="caminho/para/sidebar.js"></script>
   ```

2. Adicione um container vazio com o ID "mymenu" no body da página:
   ```html
   <div class="menu" id="mymenu"></div>
   ```

3. O script irá automaticamente preencher o container com o conteúdo do menu lateral.

### Paths Relativos

O componente sidebar detecta automaticamente a profundidade da página atual na estrutura de diretórios e calcula os caminhos relativos corretos para os recursos (como imagens e CSS).

## Manutenção

Para atualizar as informações exibidas no menu lateral (como cargo, experiência, etc.), basta editar o arquivo `sidebar.js`.

## Licença

Todos os direitos reservados. O conteúdo deste site (textos, imagens e código) não pode ser reproduzido sem autorização. 