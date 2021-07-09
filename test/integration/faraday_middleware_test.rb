require "integration_helper"
require 'moneta'
require "typhoeus/adapters/faraday"

class Circuitbox

  class FaradayMiddlewareTest < Minitest::Test
    include IntegrationHelpers

    attr_reader :connection, :success_url, :failure_url, :slow_url

    @@only_once = false
    def setup
      Circuitbox.configure do |config|
        config.default_circuit_store = Moneta.new(:Memory, expires: true)
        config.default_logger = Logger.new(File::NULL)
      end

      @connection = Faraday.new do |c|
        c.use FaradayMiddleware
        c.adapter :typhoeus # support in_parallel
      end
      @success_url = "http://localhost:4711"
      @failure_url = "http://localhost:4712"
      @slow_url = "http://localhost:4713"

      if !@@only_once
        FakeServer.create(4711, ['200', {'Content-Type' => 'text/plain'}, ["Success!"]])
        FakeServer.create(4712, ['500', {'Content-Type' => 'text/plain'}, ["Failure!"]])
        FakeServer.create_timeout(4713, 10)
        @@only_once = true
      end
    end

    def test_circuit_does_not_open_for_below_threshhold_failed_requests
      4.times { connection.get(failure_url) }
      assert_equal connection.get(success_url).status, 200
    end

    def test_failure_circuit_response
      failure_response = connection.get(failure_url)
      assert_equal failure_response.status, 503
      assert_match failure_response.original_response.body, "Failure!"
    end

    def test_open_circuit_response
      open_circuit
      open_circuit_response = connection.get(failure_url)
      assert_equal open_circuit_response.status, 503
      assert_nil open_circuit_response.original_response
      assert_kind_of Circuitbox::OpenCircuitError, open_circuit_response.original_exception
    end

    def test_closed_circuit_response
      result = connection.get(success_url)
      assert result.success?
    end

    def test_parallel_requests_closed_circuit_response
      response_1, response_2 = nil
      connection.in_parallel do
        response_1 = connection.get(success_url)
        response_2 = connection.get(success_url)
      end

      assert response_1.success?
      assert response_2.success?
    end

    def test_failed_parallel_requests_closed_circuit_response
      response_1, response_2 = nil
      connection.in_parallel do
        response_1 = connection.get(failure_url)
        response_2 = connection.get(failure_url)
      end
      # Circuitbox::FaradayMiddleware::RequestFailed exception is raised before the below assertions

      # is this the correct intended result?
      assert_equal 500, response_1.status
      assert_equal 500, response_2.status
      refute response_1.success?
      refute response_2.success?
    end

    def test_slow_parallel_requests_closed_circuit_response
      middleware_options = {
        open_circuit: lambda do |response|
          response.env[:typhoeus_timed_out] == true
        end
      }
      custom_conn = Faraday.new do |c|
        c.options.timeout = 0.1
        c.options.open_timeout = 1
        c.use FaradayMiddleware, middleware_options
        c.adapter :typhoeus
      end
      response_1, response_2 = nil
      custom_conn.in_parallel do
        response_1 = custom_conn.get(slow_url)
        response_2 = custom_conn.get(slow_url)
      end
      # Circuitbox::FaradayMiddleware::RequestFailed exception is raised before the below assertions

      # Is this the correct intended result?
      refute response_1.success?
      refute response_2.success?
    end

    def test_parallel_requests_open_circuit_response
      open_circuit
      response_1, response_2 = nil
      connection.in_parallel do
        response_1 = connection.get(failure_url)
        response_2 = connection.get(failure_url)
      end

      assert_equal response_1.status, 503
      assert_equal response_2.status, 503
    end

  end
end
