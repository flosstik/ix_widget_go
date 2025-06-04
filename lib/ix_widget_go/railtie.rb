# frozen_string_literal: true

require 'ffi'
require 'json'

module IxWidgetGo
  module TableDataFFI
    extend FFI::Library

    # Track if library is loaded
    @library_loaded = false

    # Load the Go shared library
    begin
      # Detect platform
      platform = case RbConfig::CONFIG['host_os']
      when /darwin/
        'darwin'
      when /linux/
        'linux'
      else
        raise "Unsupported platform: #{RbConfig::CONFIG['host_os']}"
      end

      # Find the gem's bin directory
      gem_root = File.expand_path('../../..', __FILE__)
      library_path = File.join(gem_root, 'bin', "libtabledata_#{platform}.so")

      # Check if library exists
      if File.exist?(library_path)
        ffi_lib library_path
        @library_loaded = true

        if defined?(Rails)
          Rails.logger.info "IxWidgetGo::TableDataFFI: Loaded library from #{library_path}"
        end
      else
        if defined?(Rails)
          Rails.logger.warn "IxWidgetGo::TableDataFFI: Library not found at #{library_path}"
        end
      end
    rescue LoadError => e
      if defined?(Rails)
        Rails.logger.warn "IxWidgetGo::TableDataFFI: Failed to load Go library - #{e.message}"
      end
    end

    # Define the FFI functions - simplified interface matching the Go implementation
    # Only attach functions if library was loaded successfully
    if @library_loaded
      begin
        attach_function :BuildData, [:string], :pointer
        attach_function :BuildRow, [:string], :pointer
        attach_function :FreeString, [:pointer], :void
      rescue => e
        @library_loaded = false
        if defined?(Rails)
          Rails.logger.warn "IxWidgetGo::TableDataFFI: Failed to attach functions - #{e.message}"
        end
      end
    else
      if defined?(Rails)
        Rails.logger.warn "IxWidgetGo::TableDataFFI: Library not loaded, functions not attached"
      end
    end

    # Check if library is available
    def self.available?
      @library_loaded && respond_to?(:BuildData) && respond_to?(:BuildRow)
    end

    class Error < StandardError; end

  # Direct FFI wrapper methods that match the original Ruby interface
  def self.build_data(calculation_data, level = 0, widget)
    return [] unless calculation_data && !calculation_data.empty?
    return [] unless available?

    # Prepare the request matching Go's BuildDataRequest structure
    request = {
      calculation_data: calculation_data,
      widget: prepare_widget(widget)
    }

    # Call Go function
    request_json = request.to_json
    response_ptr = BuildData(request_json)

    begin
      # Get response string
      response_json = response_ptr.read_string

      # Check for errors
      if response_json.include?('"error"')
        error_data = JSON.parse(response_json)
        Rails.logger.error "Go BuildData error: #{error_data['error']}" if defined?(Rails)
        return []
      end

      # Parse and return the result
      JSON.parse(response_json)
    rescue => e
      Rails.logger.error "FFI build_data error: #{e.message}" if defined?(Rails)
      []
    ensure
      # Free the C string
      FreeString(response_ptr) if response_ptr
    end
  end

  def self.build_row(breakdown_label, breakdown_tooltip, row_data, widget)
    return {} unless available?
    # Prepare the request matching Go's BuildRowRequest structure
    request = {
      breakdown_label: breakdown_label,
      breakdown_tooltip: breakdown_tooltip,
      row_data: row_data,
      widget: prepare_widget(widget)
    }

    # Call Go function
    request_json = request.to_json
    response_ptr = BuildRow(request_json)

    begin
      # Get response string
      response_json = response_ptr.read_string

      # Check for errors
      if response_json.include?('"error"')
        error_data = JSON.parse(response_json)
        Rails.logger.error "Go BuildRow error: #{error_data['error']}" if defined?(Rails)
        return {}
      end

      # Parse and return the result
      JSON.parse(response_json)
    rescue => e
      Rails.logger.error "FFI build_row error: #{e.message}" if defined?(Rails)
      {}
    ensure
      # Free the C string
      FreeString(response_ptr) if response_ptr
    end
  end

  private

  # Prepare widget data for Go
  def self.prepare_widget(widget)
    # Extract campaign targets if available
    campaign_targets = if widget.respond_to?(:campaigns_ids)
      CampaignsTarget.where(
        id: widget.settings.indicators.map(&:campaign_target_id).compact,
        campaign_id: widget.campaigns_ids
      ).map do |target|
        {
          id: target.id.to_s,
          name: target.name,
          target: target.target.to_f,
          margin: target.margin.to_f,
          revert_calcul: target.revert_calcul
        }
      end
    else
      []
    end

    # Extract schema questions if available
    schema_questions = if widget.respond_to?(:schema_presenter)
      widget.schema_presenter.questions.pluck(:name)
    else
      []
    end

    {
      settings: {
        indicators: prepare_indicators(widget.settings.indicators),
        amount_indicators: prepare_indicators(widget.settings.amount_indicators || []),
        breakdowns: widget.settings.breakdowns || [],
        concept_breakdowns: widget.settings.concept_breakdowns || [],
        order_column: widget.settings.order_column,
        order_direction: widget.settings.order_direction
      },
      schema_questions: schema_questions,
      campaign_targets: campaign_targets
    }
  end

  # Prepare indicators for Go
  def self.prepare_indicators(indicators)
    return [] unless indicators

    indicators.map do |indicator|
      {
        id: indicator.id.to_s,
        type: indicator.type,
        question: indicator.question,
        title: indicator.title,
        measure: indicator.measure,
        response_items: indicator.response_items || [],
        digits: indicator.digits || 1,
        campaign_target_id: indicator.campaign_target_id.to_s
      }
    end
  end
end

# Monkey patch to integrate with existing Ruby code
if defined?(WidgetViews::SurveyResponse::Table)
  module WidgetViews::SurveyResponse::Table::FFIExtension
    def build_data_with_ffi
      return [] if calculation_data[0].blank?
      return build_data(calculation_data, 0, widget) unless should_use_ffi?

      IxWidgetGo::TableDataFFI.build_data(calculation_data, 0, widget)
    end

    def build_row_with_ffi(breakdown_label, breakdown_tooltip, row_data)
      return build_row(breakdown_label, breakdown_tooltip, row_data, widget) unless should_use_ffi?

      IxWidgetGo::TableDataFFI.build_row(breakdown_label, breakdown_tooltip, row_data, widget)
    end

    def should_use_ffi?
      total_rows = calculation_data.values.sum { |level| level.is_a?(Hash) ? level.size : 0 }
      total_rows > 50
    end
  end

  # Apply the monkey patch
  WidgetViews::SurveyResponse::Table::Json.class_eval do
    include WidgetViews::SurveyResponse::Table::FFIExtension

    alias_method :build_data_without_ffi, :build_data
    alias_method :build_data, :build_data_with_ffi

    alias_method :build_row_without_ffi, :build_row
    alias_method :build_row, :build_row_with_ffi
  end
end
