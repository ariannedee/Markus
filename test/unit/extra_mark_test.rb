require File.dirname(__FILE__) + '/../test_helper'
require 'shoulda'

class ExtraMarkTest < Test::Unit::TestCase
  should_belong_to :result
	should_validate_presence_of :result_id
end