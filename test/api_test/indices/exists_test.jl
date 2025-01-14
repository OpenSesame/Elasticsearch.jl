using Test
using ElasticsearchClient
using Mocking
using HTTP

Mocking.activate()

found_client_response_mock = HTTP.Response(
  200,
  Dict(
    "content-type" => "application/json",
    "content-length" => 100
  ),
  nothing
)

not_found_client_response_mock = HTTP.Response(
  404,
  Dict(
    "content-type" => "application/json",
    "content-length" => 100
  ),
  nothing
)

test_name = "test"

@testset "Testing exists method" begin
  client = ElasticsearchClient.Client()

  @testset "When index found" begin
    client_patch = @patch(
      ElasticsearchClient.ElasticTransport.perform_request(::ElasticsearchClient.ElasticTransport.Client, args...; kwargs...) = 
        found_client_response_mock
    )

    apply(client_patch) do
      @test ElasticsearchClient.Indices.exists(client, index=test_name)
    end
  end

  @testset "When index not found" begin
    client_patch = @patch(
      ElasticsearchClient.ElasticTransport.perform_request(::ElasticsearchClient.ElasticTransport.Client, args...; kwargs...) =
        not_found_client_response_mock
    )

    apply(client_patch) do
      @test !ElasticsearchClient.Indices.exists(client, index=test_name)
    end
  end
end
