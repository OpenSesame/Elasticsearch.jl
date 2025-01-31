using ElasticsearchClient
using Test
using Mocking
using HTTP
using JSON
using JSON3

Mocking.activate()

serializer = JSON.json
deserializer = JSON.parse

hosts = [
  Dict{Symbol, Any}(:host => "localhost", :schema => "https"),
  Dict{Symbol, Any}(:host => "127.0.0.1", :schema => "http", :port => 9250),
  Dict{Symbol, Any}(:host => "aws_host", :port => 9200),
]

options = Dict(
  :compression => true,
  :retry_on_status => [400, 404],
  :transport_options => Dict{Symbol, Any}(
    :headers => Dict(
      "test-api-key" => "key",
      :content_type => "application/json"
    ),
    :resurrect_timeout => 0
  ),
  :verbose => 0
)

successful_health_response_mock = HTTP.Response(
  200,
  Dict("content-type" => "application/json"),
  JSON.json(
    Dict(
      "cluster_name" => "name",
      "timed_out" => false
    )
  )
)

successful_search_response_mock = HTTP.Response(
  200,
  Dict("content-type" => "application/json"),
  JSON.json(
    Dict(
      "took" => 12
    )
  )
)

not_found_response_mock = HTTP.Response(
  404,
  Dict("content-type" => "application/json"),
  JSON.json(
    Dict(
      "status" => "Not Found"
    )
  )
)

internal_error_response_mock = HTTP.Response(
  500,
  Dict("content-type" => "application/json"),
  JSON.json(
    Dict(
      "status" => "Error"
    )
  )
)

nodes_response_mock = HTTP.Response(
  200,
  Dict("content-type" => "application/json"),
  Dict(
    "nodes" => Dict(
      "node_id_1" => Dict(
        "roles" => ["master"],
        "name" => "Name Node 1",
        "http" => Dict("publish_address" => "127.0.0.1:9250")
      ),
      "node_id_2" => Dict(
        "roles" => ["master"],
        "name" => "Name Node 2",
        "http" => Dict("publish_address" => "testhost1.com:9250")
      ),
      "node_id_3" => Dict(
        "roles" => ["master"],
        "name" => "Name Node 3",
        "http" => Dict("publish_address" => "inet[/127.0.0.2:9250]")
      ),
      "node_id_4" => Dict(
        "roles" => ["master"],
        "name" => "Name Node 4",
        "http" => Dict("publish_address" => "example.com/127.0.0.1:9250")
      ),
      "node_id_5" => Dict(
        "roles" => ["master"],
        "name" => "Name Node 5",
        "http" => Dict("publish_address" => "[::1]:9250")
      ), 
    )
  ) |> JSON.json
)

@testset "Transport test" begin
  @testset "Transport initialization" begin
    transport = ElasticsearchClient.ElasticTransport.Transport(;hosts, options, http_client=HTTP, serializer=serializer, deserializer=deserializer)

    @test length(transport.connections.connections) == length(hosts)
    @test transport.use_compression == options[:compression]
    @test transport.retry_on_status == options[:retry_on_status]
  end

  @testset "Performing request" begin
    transport = ElasticsearchClient.ElasticTransport.Transport(;hosts, options=options, http_client=HTTP, serializer=serializer, deserializer=deserializer)

    @testset "Testing with successful response" begin
      @testset "Testing GET request with params" begin
        http_patch = @patch HTTP.request(args...;kwargs...) = successful_health_response_mock

        apply(http_patch) do 
          response = ElasticsearchClient.ElasticTransport.perform_request(transport, "GET", "/_cluster/health"; params = Dict("pretty" => true))

          @test response isa HTTP.Response
          @test response.status == 200
          @test haskey(response.body, "cluster_name")
        end
      end

      @testset "Testing POST request with params" begin
        http_patch = @patch HTTP.request(args...;kwargs...) = successful_search_response_mock

        apply(http_patch) do
          response = ElasticsearchClient.ElasticTransport.perform_request(transport, "POST", "/_search"; body = Dict("query" => Dict("match_all" => Dict())))

          @test response isa HTTP.Response
          @test response.status == 200
          @test haskey(response.body, "took")
        end
      end

      @testset "Testing POST request with blank body" begin
        http_patch = @patch HTTP.request(args...;kwargs...) = successful_search_response_mock

        apply(http_patch) do
          response = ElasticsearchClient.ElasticTransport.perform_request(transport, "POST", "/_search")

          @test response isa HTTP.Response
          @test response.status == 200
          @test haskey(response.body, "took")
        end
      end

      @testset "Testing POST request with NamedTuple body" begin
        http_patch = @patch HTTP.request(args...;kwargs...) = successful_search_response_mock

        body = (
          query=(
            match_all=Dict(),
          ),
        )

        apply(http_patch) do
          response = ElasticsearchClient.ElasticTransport.perform_request(transport, "POST", "/_search")

          @test response isa HTTP.Response
          @test response.status == 200
          @test haskey(response.body, "took")
        end
      end

      @testset "Testing unsuccessful response with retry" begin
        count_tries = 0

        http_patch = @patch HTTP.request(args...;kwargs...) = begin
          count_tries += 1

          not_found_response_mock
        end

        apply(http_patch) do
          @test_throws ElasticsearchClient.ElasticTransport.NotFound ElasticsearchClient.ElasticTransport.perform_request(
            transport,
            "POST",
            "/_search"; 
            body = Dict("query" => Dict("match_all" => Dict()))
          )

          @test count_tries == ElasticsearchClient.ElasticTransport.DEFAULT_MAX_RETRIES
        end
      end

      @testset "Testing unsuccessful response without retries" begin
        count_tries = 0

        http_patch = @patch HTTP.request(args...;kwargs...) = begin
          count_tries += 1

          internal_error_response_mock
        end

        apply(http_patch) do
          @test_throws ElasticsearchClient.ElasticTransport.InternalServerError ElasticsearchClient.ElasticTransport.perform_request(
            transport,
            "POST",
            "/_search"; 
            body = Dict("query" => Dict("match_all" => Dict()))
          )

          @test count_tries == 1
        end
      end

      @testset "Testing with connect error" begin
        http_patch = @patch HTTP.request(args...;kwargs...) = throw(HTTP.ConnectError("Error", "Error"))

        apply(http_patch) do
          @test_throws HTTP.ConnectError ElasticsearchClient.ElasticTransport.perform_request(
            transport,
            "POST",
            "/_search"; 
            body = Dict("query" => Dict("match_all" => Dict()))
          )

          @test length(ElasticsearchClient.ElasticTransport.Connections.dead(transport.connections)) == 1
        end
      end

      @testset "Testing GET request with custom serializer/deserializer" begin
        http_patch = @patch HTTP.request(args...;kwargs...) = successful_health_response_mock
        custom_transport = ElasticsearchClient.ElasticTransport.Transport(;
          hosts,
          options=options,
          http_client=HTTP,
          serializer=JSON3.write,
          deserializer=JSON3.read
        )


        apply(http_patch) do 
          response = ElasticsearchClient.ElasticTransport.perform_request(custom_transport, "GET", "/_cluster/health"; params = Dict("pretty" => true))

          @test response isa HTTP.Response
          @test response.status == 200
          @test haskey(response.body, :cluster_name)
        end
      end
    end
  end

  @testset "Testing sniffing" begin
    @testset "Testing successful sniffing" begin
      http_patch = @patch HTTP.request(args...;kwargs...) = nodes_response_mock

      transport = ElasticsearchClient.ElasticTransport.Transport(;hosts, options=options, http_client=HTTP, serializer=serializer, deserializer=deserializer)

      apply(http_patch) do
        hosts = ElasticsearchClient.ElasticTransport.sniff_hosts(transport) |>
          hosts -> sort(hosts, by = host -> host[:id])

        @test hosts[begin][:host] == "127.0.0.1"
        @test hosts[begin][:port] == 9250

        @test hosts[begin + 1][:host] == "testhost1.com"
        @test hosts[begin + 1][:port] == 9250

        @test hosts[begin + 2][:host] == "127.0.0.2"
        @test hosts[begin + 2][:port] == 9250

        @test hosts[begin + 3][:host] == "example.com"
        @test hosts[begin + 3][:port] == 9250

        @test hosts[begin + 4][:host] == "::1"
        @test hosts[begin + 4][:port] == 9250
      end
    end

    @testset "Testing sniffing timeout" begin
      http_patch = @patch HTTP.request(args...;kwargs...) = sleep(ElasticsearchClient.ElasticTransport.DEFAULT_SNIFFING_TIMEOUT + 0.5)

      transport = ElasticsearchClient.ElasticTransport.Transport(;hosts, options=options, http_client=HTTP, serializer=serializer, deserializer=deserializer)

      apply(http_patch) do
        @test_throws ElasticsearchClient.ElasticTransport.SniffingTimetoutError ElasticsearchClient.ElasticTransport.sniff_hosts(transport)
      end
    end
  end

  @testset "Testing reload connections" begin
    http_patch = @patch HTTP.request(args...;kwargs...) = nodes_response_mock

    transport = ElasticsearchClient.ElasticTransport.Transport(;hosts, options=options, http_client=HTTP, serializer=serializer, deserializer=deserializer)

    apply(http_patch) do
      ElasticsearchClient.ElasticTransport.reload_connections!(transport)
      nodes = JSON.parse(String(nodes_response_mock.body))["nodes"]

      @test length(transport.connections) == length(nodes)
    end
  end
end