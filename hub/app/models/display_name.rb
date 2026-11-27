# Plain public labels shared by allowlist, profile and optional identity claims.
module DisplayName
  MAX_LENGTH = 80

  def self.valid?(value)
    value.is_a?(String) && value.length <= MAX_LENGTH && !value.match?(/[<>\p{Cc}]|\S+@\S+/)
  end
end
