FROM ruby:4.0.9-alpine3.24

COPY Gemfile* ./

RUN apk add --no-cache --virtual .build-deps build-base && \
    bundle install && \
    apk del .build-deps

COPY dependabot_prometheus_metrics dependabot_prometheus_metrics.rb ./

RUN addgroup -g 1001 app; \
    adduser -u 1001 -D --ingroup app app --home ./

USER app
