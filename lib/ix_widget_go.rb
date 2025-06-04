# frozen_string_literal: true

require_relative "ix_widget_go/version"
require_relative "ix_widget_go/railtie" if defined?(Rails::Railtie)

module IxWidgetGo
  class Error < StandardError; end
  # Your code goes here...
end
