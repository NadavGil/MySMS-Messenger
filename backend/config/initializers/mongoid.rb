# Loads config/mongoid.yml for the current Rails environment. The Mongo URI
# itself is entirely env-driven (see config/mongoid.yml) so relocating the
# datastore (local Docker -> Atlas -> elsewhere) is a config-only change
# (tech-design.md §2.9, HLD §7.2).
Mongoid.load!(Rails.root.join("config/mongoid.yml"), Rails.env)
