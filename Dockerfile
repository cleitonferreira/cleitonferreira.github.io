FROM ruby:3.1-alpine

RUN apk add --no-cache build-base git nodejs npm

WORKDIR /srv/jekyll

COPY Gemfile Gemfile.lock jekyll-theme-chirpy.gemspec ./
RUN bundle install

COPY package*.json ./
RUN npm install

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 4000 35729

ENTRYPOINT ["docker-entrypoint.sh"]
