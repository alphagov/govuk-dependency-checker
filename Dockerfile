FROM ruby:3.2-alpine

COPY Gemfile* ./

RUN bundle install

COPY dependabot_time_to_merge dependabot_time_to_merge.rb ./

RUN addgroup -g 1001 app; \
    adduser -u 1001 -D --ingroup app app --home ./

USER app
