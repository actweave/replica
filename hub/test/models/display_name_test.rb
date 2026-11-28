require "test_helper"

class DisplayNameTest < ActiveSupport::TestCase
  test "rejects email addresses with spaces around the at sign" do
    assert_not DisplayName.valid?("Ada @example.com")
  end
end
