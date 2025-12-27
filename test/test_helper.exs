alias Ecto.Adapters.SQL.Sandbox
alias EctoLiteFS.Test.Repo

Application.ensure_all_started(:briefly)

{:ok, _} = Repo.start_link()

Sandbox.mode(Repo, :manual)

# Setup Mimic for mocking RPC calls in middleware tests
Mimic.copy(EctoLiteFS.RPC)

ExUnit.start()
