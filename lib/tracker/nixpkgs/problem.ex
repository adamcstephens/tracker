defmodule Tracker.Nixpkgs.Problem do
  use TypedStruct

  @derive Jason.Encoder
  typedstruct enforce: true do
    field :id, String.t()
    field :kind, String.t()
    field :message, String.t()
    field :urls, [String.t()], default: []
  end

  use Ash.Type.NewType,
    subtype_of: :struct,
    constraints: [
      instance_of: Tracker.Nixpkgs.Problem,
      fields: [
        id: [type: :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]],
        kind: [type: :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]],
        message: [
          type: :string,
          allow_nil?: false,
          constraints: [trim?: false, allow_empty?: true]
        ],
        urls: [
          type: {:array, :string},
          allow_nil?: false,
          constraints: [items: [trim?: false, allow_empty?: true]]
        ]
      ]
    ]

  def from_nif(%{"id" => id, "kind" => kind, "message" => message, "urls" => urls}) do
    %__MODULE__{id: id, kind: kind, message: message, urls: urls}
  end
end
