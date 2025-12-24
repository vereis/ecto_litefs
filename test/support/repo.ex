defmodule EctoLiteFS.Test.Repo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :ecto_litefs,
    adapter: Ecto.Adapters.SQLite3
end
