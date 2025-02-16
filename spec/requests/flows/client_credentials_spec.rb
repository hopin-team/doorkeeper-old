# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Client Credentials Request" do
  let(:client) { FactoryBot.create :application }

  context "with a valid request" do
    it "authorizes the client and returns the token response" do
      headers = authorization client.uid, client.secret
      params  = { grant_type: "client_credentials" }

      post "/oauth/token", params: params, headers: headers

      expect(json_response).to match(
        "access_token" => Doorkeeper::AccessToken.first.token,
        "token_type" => "Bearer",
        "expires_in" => Doorkeeper.configuration.access_token_expires_in,
        "created_at" => an_instance_of(Integer),
      )
    end

    context "with scopes" do
      before do
        optional_scopes_exist :write
        default_scopes_exist :public
      end

      it "adds the scope to the token an returns in the response" do
        headers = authorization client.uid, client.secret
        params  = { grant_type: "client_credentials", scope: "write" }

        post "/oauth/token", params: params, headers: headers

        expect(json_response).to include(
          "access_token" => Doorkeeper::AccessToken.first.token,
          "scope" => "write",
        )
      end

      context "when scopes are default" do
        it "adds the scope to the token an returns in the response" do
          headers = authorization client.uid, client.secret
          params  = { grant_type: "client_credentials", scope: "public" }

          post "/oauth/token", params: params, headers: headers

          expect(json_response).to include(
            "access_token" => Doorkeeper::AccessToken.first.token,
            "scope" => "public",
          )
        end
      end

      context "when scopes are invalid" do
        it "does not authorize the client and returns the error" do
          headers = authorization client.uid, client.secret
          params  = { grant_type: "client_credentials", scope: "random" }

          post "/oauth/token", params: params, headers: headers

          expect(response.status).to eq(400)
          expect(json_response).to match(
            "error" => "invalid_scope",
            "error_description" => translated_error_message(:invalid_scope),
          )
        end
      end
    end
  end

  context "with resource indicators" do
    before do
      Doorkeeper.configuration.instance_variable_set(
        :@use_resource_indicators, true,
      )
    end

    scenario "resource owner authorizes the client with default scopes" do
      client.update(name: "admin")

      headers = authorization client.uid, client.secret
      params  = { grant_type: "client_credentials", resource: "http://example.com/resource1" }

      post "/oauth/token", params: params, headers: headers

      expect(json_response).to match(
        "access_token" => Doorkeeper::AccessToken.first.token,
        "token_type" => "Bearer",
        "expires_in" => 7200,
        "created_at" => an_instance_of(Integer),
      )
      expect(Doorkeeper::AccessToken.first.resource_indicators).to contain_exactly("http://example.com/resource1")
    end

    scenario "with multiple resource indicators" do
      client.update(name: "admin")

      headers = authorization client.uid, client.secret
      params  = "#{{
        grant_type: "client_credentials",
        resource: "http://example.com/resource1",
      }.to_param}&#{{ resource: "http://example.com/resource2" }.to_param}"

      post "/oauth/token", params: params, headers: headers

      expect(json_response).to match(
        "access_token" => Doorkeeper::AccessToken.first.token,
        "token_type" => "Bearer",
        "expires_in" => 7200,
        "created_at" => an_instance_of(Integer),
      )

      expect(Doorkeeper::AccessToken.first.resource_indicators).to contain_exactly("http://example.com/resource1", "http://example.com/resource2")
    end
  end

  context "when configured to check application supported grant flow" do
    before do
      Doorkeeper.configuration.instance_variable_set(
        :@allow_grant_flow_for_client,
        ->(_grant_flow, client) { client.name == "admin" },
      )
    end

    scenario "forbids the request when doesn't satisfy condition" do
      client.update(name: "sample app")

      headers = authorization client.uid, client.secret
      params  = { grant_type: "client_credentials" }

      post "/oauth/token", params: params, headers: headers

      expect(json_response).to match(
        "error" => "unauthorized_client",
        "error_description" => translated_error_message(:unauthorized_client),
      )
    end

    scenario "allows the request when satisfies condition" do
      client.update(name: "admin")

      headers = authorization client.uid, client.secret
      params  = { grant_type: "client_credentials" }

      post "/oauth/token", params: params, headers: headers

      expect(json_response).to match(
        "access_token" => Doorkeeper::AccessToken.first.token,
        "token_type" => "Bearer",
        "expires_in" => 7200,
        "created_at" => an_instance_of(Integer),
      )
    end
  end

  context "when application scopes contain some of the default scopes and no scope is passed" do
    before do
      client.update(scopes: "read write public")
    end

    it "issues new token with one default scope that are present in application scopes" do
      default_scopes_exist :public

      headers = authorization client.uid, client.secret
      params  = { grant_type: "client_credentials" }

      expect do
        post "/oauth/token", params: params, headers: headers
      end.to change { Doorkeeper::AccessToken.count }.by(1)

      token = Doorkeeper::AccessToken.first

      expect(token.application_id).to eq client.id
      expect(json_response).to include(
        "access_token" => token.token,
        "scope" => "public",
      )
    end

    it "issues new token with multiple default scopes that are present in application scopes" do
      default_scopes_exist :public, :read, :update

      headers = authorization client.uid, client.secret
      params  = { grant_type: "client_credentials" }

      expect do
        post "/oauth/token", params: params, headers: headers
      end.to change { Doorkeeper::AccessToken.count }.by(1)

      token = Doorkeeper::AccessToken.first

      expect(token.application_id).to eq client.id
      expect(json_response).to include(
        "access_token" => token.token,
        "scope" => "public read",
      )
    end
  end

  context "when request is invalid" do
    it "does not authorize the client and returns the error" do
      headers = {}
      params  = { grant_type: "client_credentials" }

      post "/oauth/token", params: params, headers: headers

      expect(response.status).to eq(401)

      expect(json_response).to match(
        "error" => "invalid_client",
        "error_description" => translated_error_message(:invalid_client),
      )
    end
  end

  context "when revoke_previous_client_credentials_token is true" do
    before do
      allow(Doorkeeper.config).to receive(:reuse_access_token).and_return(false)
      allow(Doorkeeper.config).to receive(:revoke_previous_client_credentials_token?).and_return(true)
    end

    it "revokes the previous token" do
      headers = authorization client.uid, client.secret
      params  = { grant_type: "client_credentials" }

      post "/oauth/token", params: params, headers: headers
      expect(json_response).to include("access_token" => Doorkeeper::AccessToken.first.token)

      token = Doorkeeper::AccessToken.first

      post "/oauth/token", params: params, headers: headers
      expect(json_response).to include("access_token" => Doorkeeper::AccessToken.last.token)

      expect(token.reload).to be_revoked
      expect(Doorkeeper::AccessToken.last).not_to be_revoked
    end

    context "with a simultaneous request" do
      let!(:access_token) { FactoryBot.create :access_token, resource_owner_id: nil }

      before do
        allow(Doorkeeper.config.access_token_model).to receive(:matching_token_for) { access_token }
        allow(access_token).to receive(:revoked?).and_return(true)
      end

      it "returns an error" do
        headers = authorization client.uid, client.secret
        params  = { grant_type: "client_credentials" }

        post "/oauth/token", params: params, headers: headers

        expect(json_response).to match(
          "error" => "invalid_token_reuse",
          "error_description" => translated_error_message(:server_error),
        )
      end
    end
  end

  def authorization(username, password)
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials username, password
    { "HTTP_AUTHORIZATION" => credentials }
  end
end
