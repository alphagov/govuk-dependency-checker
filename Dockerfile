FROM ruby:3.2-alpine

COPY Gemfile* ./

RUN bundle install

COPY dependabot_metrics dependabot_metrics.rb ./

RUN addgroup -g 1001 app; \
    adduser -u 1001 -D --ingroup app app --home ./

USER app
