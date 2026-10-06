# syntax = docker/dockerfile:1
# Campfire on Rage and Sequel, with the Rails reference image's container interface: app in
# /rails, storage in /rails/storage/{db,files}, uid 1000, HTTP on HTTP_PORT, its environment.
ARG RUBY_VERSION=3.4.10
ARG REFERENCE_IMAGE=campfire-reference:app

FROM ${REFERENCE_IMAGE} AS reference

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
WORKDIR /rails
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libvips libjemalloc2 redis && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
ENV BUNDLE_DEPLOYMENT="1" BUNDLE_PATH="/usr/local/bundle" BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" RUBY_YJIT_ENABLE="1"

FROM base AS build
RUN apt-get update -qq && \
    apt-get install -y build-essential git pkg-config libyaml-dev libssl-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache
COPY . .
# The reference's digested assets, so asset paths match it exactly.
COPY --from=reference /rails/public/assets /rails/public/assets

FROM base
RUN groupadd --system --gid 1000 rails && useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
COPY --from=build --chown=rails:rails /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /rails /rails
RUN mkdir -p /rails/storage/db /rails/storage/files && chown -R rails:rails /rails/storage
USER 1000:1000
EXPOSE 80
CMD ["bin/start"]
