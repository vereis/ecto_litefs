defmodule TestApp.Repo do
  use Ecto.Repo,
    otp_app: :test_app,
    adapter: Ecto.Adapters.SQLite3

  use EctoMiddleware

  @impl EctoMiddleware
  def middleware(_resource, _action), do: [EctoLiteFS.Middleware]
end
