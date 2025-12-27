defmodule TestApp.Item do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  schema "items" do
    field(:name, :string)
    field(:created_at, :string)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
