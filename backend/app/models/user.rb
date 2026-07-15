# Mongoid document, unnamespaced top-level ::User (app/models/ is a default
# Zeitwerk autoload root, same pattern as MessageDocument — tech-design.md
# §13.2). Backs Bonus 1 authentication (has_secure_password / bcrypt).
class User
  include Mongoid::Document
  include Mongoid::Timestamps
  # CONFIRMED on the director's first real boot (post-live-run): Mongoid
  # does NOT auto-include this the way ActiveRecord::Base does, so
  # `has_secure_password` raised `NameError: undefined local variable or
  # method 'has_secure_password'` without it. bcrypt (the Gemfile
  # dependency) only supplies BCrypt::Password itself; the
  # has_secure_password DSL method comes from this ActiveModel module.
  include ActiveModel::SecurePassword
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
