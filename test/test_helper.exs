alias Ecto.Adapters.SQL.Sandbox
alias EctoLiteFS.Test.Repo

{:ok, _} = Repo.start_link()

Sandbox.mode(Repo, :manual)

ExUnit.start()
