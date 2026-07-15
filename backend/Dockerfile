# ---- build stage: compile gems (needs a C toolchain) ----
FROM ruby:3.3-slim AS build
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle
# build-essential -> gcc/make for bcrypt + bson native ext; git for git_source
# gems; libyaml-dev for psych. No libpq/sqlite (Mongoid, not ActiveRecord).
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      build-essential git libyaml-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && bundle clean --force \
    && rm -rf "${BUNDLE_PATH}"/ruby/*/cache
COPY . .
RUN bundle exec bootsnap precompile app/ lib/ || true

# ---- final stage: lean runtime, no compilers ----
FROM ruby:3.3-slim AS final
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle
# Runtime libs only. No build-essential. tzdata for UTC timestamp formatting.
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash app
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
RUN chown -R app:app /app
USER app
EXPOSE 8080
# Bind 0.0.0.0 (NOT localhost) so Fly's proxy can reach the process; honor the
# PORT Fly injects, defaulting to 8080 to match fly.toml internal_port (§14.2).
CMD ["sh", "-c", "bin/rails server -b 0.0.0.0 -p ${PORT:-8080}"]
