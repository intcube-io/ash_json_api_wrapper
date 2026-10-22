<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Authentication

Requests go through the Tesla module of a resource (`tesla` in `json_api_wrapper`), so
authentication is Tesla middleware.

## Static credentials

```elixir
defmodule MyApp.ApiTesla do
  use Tesla

  plug Tesla.Middleware.Headers, [{"x-api-key", Application.fetch_env!(:my_app, :api_key)}]
end
```

Middleware options are evaluated at compile time. Read secrets at runtime instead, for example
in a small middleware of your own, or with `AshJsonApiWrapper.Tesla.BearerToken`, which reads
its config on every request.

## Bearer tokens from a token endpoint

`AshJsonApiWrapper.Tesla.BearerToken` gets short-lived tokens from a token endpoint, caches
them, refreshes them before they expire, and retries a request once with a new token when the
API answers `401`. Concurrent requests share one refresh.

Microsoft identity platform, client credentials:

```elixir
defmodule MyApp.GraphTesla do
  use Tesla

  plug AshJsonApiWrapper.Tesla.BearerToken, config: {:my_app, :graph_auth}
end
```

```elixir
# config/runtime.exs
config :my_app, :graph_auth,
  token_url:
    "https://login.microsoftonline.com/#{System.fetch_env!("GRAPH_TENANT_ID")}/oauth2/v2.0/token",
  client_id: System.fetch_env!("GRAPH_CLIENT_ID"),
  client_secret: System.fetch_env!("GRAPH_CLIENT_SECRET"),
  scope: "https://graph.microsoft.com/.default"
```

An API that exchanges an API key for a token:

```elixir
config :my_app, :reports_auth,
  token_url: "https://reports.example.com/auth/token",
  grant: :custom,
  body_format: :json,
  params: %{"apiKey" => System.fetch_env!("REPORTS_API_KEY")},
  token_key: "token",
  expires_in_key: "ttl"
```

See `AshJsonApiWrapper.Tesla.BearerToken` for all options. Interactive flows (authorization code,
device code) are not supported.
