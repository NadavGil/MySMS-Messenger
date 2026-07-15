# CORS for the Angular dev server (tech-design.md §2.10, CP12). credentials:
# true is required so the signed CurrentIdentity cookie (CP5) round-trips;
# per the CORS spec this means CORS_ORIGINS can never be "*" - origins must
# be explicit. The Angular HttpClient calls must set withCredentials: true
# to match (see tech-design.md §8.3, already done in MessagesApiService).
#
# SECURITY FIX (qa-security-review-bonus2-deploy.md, High/Major finding):
# a bare ENV.fetch(..., "http://localhost:4200") default silently degrades
# in production if CORS_ORIGINS is never set on the deploy target - the
# app boots fine, /health returns 200, and every real cross-origin request
# from the deployed frontend gets rejected by the browser with no server-
# side error at all (a classic silent-failure demo-day trap). Match the
# same "fail loudly at boot" discipline already used for SECRET_KEY_BASE
# and MONGO_URI in production: only fall back to localhost outside
# production; require it explicitly in production.
cors_origins = if Rails.env.production?
                 ENV.fetch("CORS_ORIGINS") { raise ArgumentError, "CORS_ORIGINS must be set in production (comma-separated allowed origins, e.g. the deployed frontend's URL)" }
               else
                 ENV.fetch("CORS_ORIGINS", "http://localhost:4200")
               end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins cors_origins.split(",")

    resource "/api/*",
      headers: :any,
      methods: [:get, :post, :delete, :options], # :delete for DELETE /api/v1/auth/logout (tech-design.md §13.5)
      credentials: true
  end
end
