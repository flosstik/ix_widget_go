# frozen_string_literal: true

require 'ffi'
require 'json'
require 'rails/railtie'

module IxWidgetGo
  class Railtie < Rails::Railtie
    config.after_initialize do
      # Log library loading status after Rails is initialized
      if IxWidgetGo::TableDataFFI.available?
        Rails.logger.info "IxWidgetGo::TableDataFFI: Go library loaded successfully from #{IxWidgetGo::TableDataFFI.library_path}"
      else
        Rails.logger.warn "IxWidgetGo::TableDataFFI: Go library not available - using Ruby implementation"
      end

      # Apply monkey patch after Rails is initialized
      if defined?(WidgetViews::SurveyResponse::Table)
        module WidgetViews::SurveyResponse::Table::FFIExtension
          def build_data(level: 0, path: "Total", acc: [])
            return [] if calculation_data[0].blank?
            return super unless should_use_ffi? && IxWidgetGo::TableDataFFI.available?

            IxWidgetGo::TableDataFFI.build_data(calculation_data, level, widget)
          end

          def build_row(breakdown_label, breakdown_tooltip, row_data)
            return super unless should_use_ffi? && IxWidgetGo::TableDataFFI.available?

            IxWidgetGo::TableDataFFI.build_row(breakdown_label, breakdown_tooltip, row_data, widget)
          end

          def should_use_ffi?
            true
          end
        end

        # Apply the monkey patch using prepend (modern Ruby way)
        WidgetViews::SurveyResponse::Table::Json.prepend(WidgetViews::SurveyResponse::Table::FFIExtension)

        Rails.logger.info "IxWidgetGo: Monkey patch applied to WidgetViews::SurveyResponse::Table::Json"
      else
        Rails.logger.warn "IxWidgetGo: WidgetViews::SurveyResponse::Table not found - monkey patch not applied"
      end
    end
  end
  module TableDataFFI
    extend FFI::Library

    # Track if library is loaded
    @library_loaded = false
    @library_path = nil

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
        @library_path = library_path
      end
    rescue LoadError => e
      # Silently fail - will log error after Rails initializes
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
      end
    end

    # Check if library is available
    def self.available?
      @library_loaded && respond_to?(:BuildData) && respond_to?(:BuildRow)
    end

    # Get the library path (for logging)
    def self.library_path
      @library_path
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
          Rails.logger.error "Go BuildData error: #{error_data['error']}" if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          return []
        end

        # Parse and return the result
        JSON.parse(response_json)
      rescue => e
        Rails.logger.error "FFI build_data error: #{e.message}" if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
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
          Rails.logger.error "Go BuildRow error: #{error_data['error']}" if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          return {}
        end

        # Parse and return the result
        JSON.parse(response_json)
      rescue => e
        Rails.logger.error "FFI build_row error: #{e.message}" if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
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
end
