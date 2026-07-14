# CORS for the Angular dev server (tech-design.md §2.10, CP12). credentials:
# true is required so the signed CurrentIdentity cookie (CP5) round-trips;
# per the CORS spec this means CORS_ORIGINS can never be "*" - origins must
# be explicit. The Angular HttpClient calls must set withCredentials: true
# to match (see tech-design.md §8.3, already done in MessagesApiService).
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("CORS_ORIGINS", "http://localhost:4200").split(",")

    resource "/api/*",
      headers: :any,
      methods: [:get, :post, :options],
      credentials: true
  end
end
