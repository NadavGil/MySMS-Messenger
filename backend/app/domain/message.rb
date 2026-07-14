module Domain
  # Plain value object that crosses the DAL boundary. Controllers/services
  # only ever see Domain::Message — never the Mongoid document
  # (MessageDocument) directly (tech-design.md §3.4). Kept as a Struct
  # (rather than Ruby's Data.define) for broader Ruby-version compatibility.
  Message = Struct.new(
    :id, :to_number, :body, :owner_id, :status, :external_sid, :created_at,
    keyword_init: true
  )
end
