# ---- build stage: compile gems (needs a C toolchain) ----
FROM ruby:3.3.0-slim AS build
ENV RAILS_ENV=production \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle
# build-essential -> gcc/make for bcrypt + bson native ext; git for git_source
# gems; libyaml-dev for psych. No libpq/sqlite (Mongoid, not ActiveRecord).
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      build-essential git libyaml-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# NOTE (post-live-run audit): no Gemfile.lock is committed to this repo -
# the sandbox that built this project never had rubygems.org access to
# generate one for real (same standing limitation as everywhere else in
# this codebase). BUNDLE_DEPLOYMENT=1 requires an exact pre-existing lock
# and `COPY Gemfile Gemfile.lock` would fail outright with no lock file to
# copy. Deliberately NOT using deployment mode here: `bundle install`
# resolves and writes its own Gemfile.lock during the build instead, which
# works correctly but does NOT pin the resolution across builds. Once a
# real Gemfile.lock is generated somewhere with network access (e.g. the
# director's own machine, which already ran `bundle install` successfully)
# and committed to the repo, switch back to `COPY Gemfile Gemfile.lock ./`
# + `BUNDLE_DEPLOYMENT=1` for reproducible, frozen installs.
COPY Gemfile ./
RUN bundle install && bundle clean --force \
    && rm -rf "${BUNDLE_PATH}"/ruby/*/cache
COPY . .
RUN bundle exec bootsnap precompile app/ lib/ || true

# ---- final stage: lean runtime, no compilers ----
FROM ruby:3.3.0-slim AS final
ENV RAILS_ENV=production \
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
# Bind 0.0.0.0 (NOT localhost) so the host's proxy can reach the process;
# honor the PORT the platform injects (Render sets this automatically),
# defaulting to 8080 to match render.yaml (§14.2).
CMD ["sh", "-c", "bin/rails server -b 0.0.0.0 -p ${PORT:-8080}"]
