# Mongoid document, unnamespaced top-level ::User (app/models/ is a default
# Zeitwerk autoload root, same pattern as MessageDocument — tech-design.md
# §13.2). Backs Bonus 1 authentication (has_secure_password / bcrypt).
class User
  include Mongoid::Document
  include Mongoid::Timestamps
  # If `has_secure_password` raises NoMethodError at boot, add explicitly:
  #   include ActiveModel::SecurePassword
  # (ActiveRecord auto-includes it; Mongoid versions vary. Confirmed fine at
  # CP13 in this environment's Gemfile.lock — bcrypt gem is what actually
  # supplies BCrypt::Password; has_secure_password itself ships with
  # ActiveModel, which Mongoid apps already pull in via activesupport deps.)
  has_secure_password

  field :username,        type: String
  field :password_digest, type: String # required by has_secure_password

  # Case policy (tech-design.md §13.2, MY CALL upstream): usernames are
  # case-INSENSITIVE for identity but stored in their normalized lowercase
  # form. Normalize before validation so both the unique index and login
  # lookups are trivial exact matches.
  before_validation { self.username = username.downcase.strip if username.is_a?(String) }

  validates :username, presence: true,
                       uniqueness: true, # app-level guard (racy; index is authoritative)
                       format: { with: /\A[a-z0-9_]{3,30}\z/,
                                 message: "must be 3-30 chars: lowercase letters, digits, underscore" }
  # has_secure_password already validates password presence on create and
  # enforces bcrypt's 72-byte max. Add a sane minimum.
  validates :password, length: { minimum: 8 }, allow_nil: true

  # Authoritative uniqueness guard (uniqueness validation alone is racy).
  index({ username: 1 }, { unique: true })
end
