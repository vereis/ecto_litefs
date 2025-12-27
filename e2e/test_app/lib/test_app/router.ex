defmodule TestApp.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/status" do
    primary_node =
      case EctoLiteFS.get_primary(TestApp.Repo) do
        {:ok, node} -> node
        _ -> nil
      end

    status = %{
      node: node(),
      is_primary: EctoLiteFS.is_primary?(TestApp.Repo),
      primary_node: primary_node,
      tracker_ready: EctoLiteFS.tracker_ready?(TestApp.Repo)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(status))
  end

  get "/items" do
    import Ecto.Query

    items = TestApp.Repo.all(from(i in TestApp.Item, order_by: i.id))

    items_json =
      Enum.map(items, fn item ->
        %{id: item.id, name: item.name, created_at: item.created_at}
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(items_json))
  end

  post "/items" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"name" => name} = Jason.decode!(body)

    changeset = TestApp.Item.changeset(%TestApp.Item{}, %{name: name})

    case TestApp.Repo.insert(changeset) do
      {:ok, item} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(%{status: "created", name: item.name, id: item.id}))

      {:error, changeset} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: inspect(changeset.errors)}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
