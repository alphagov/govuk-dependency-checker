FROM --platform=$TARGETPLATFORM ruby:3.3-alpine

COPY Gemfile* ./

RUN bundle install

COPY dependabot_prometheus_metrics dependabot_prometheus_metrics.rb ./

RUN addgroup -g 1001 app; \
    adduser -u 1001 -D --ingroup app app --home ./

USER app
