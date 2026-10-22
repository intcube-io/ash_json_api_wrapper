# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshJsonApiWrapper.ODataTest do
  use ExUnit.Case
  require Ash.Query
  import Mox

  setup :verify_on_exit!

  # An excerpt of the public Microsoft Graph v1.0 metadata (users, groups, applications), and
  # responses written from the public Graph docs.
  @metadata File.read!("test/support/odata/graph_v1_metadata.xml")
  @users_page_1 File.read!("test/support/odata/users_page_1.json")
  @users_page_2 File.read!("test/support/odata/users_page_2.json")
  @groups File.read!("test/support/odata/groups.json")
  @applications File.read!("test/support/odata/applications.json")
  @error File.read!("test/support/odata/error.json")

  defmodule TestingTesla do
    use Tesla

    adapter(AshJsonApiWrapper.MockAdapter)
  end

  defmodule User do
    use Ash.Resource,
      domain: AshJsonApiWrapper.ODataTest.Domain,
      data_layer: AshJsonApiWrapper.DataLayer,
      validate_domain_inclusion?: false

    json_api_wrapper do
      tesla(TestingTesla)

      dialect(
        {AshJsonApiWrapper.Dialect.OData,
         count: true, consistency_level: "eventual", properties: [email: "mail"]}
      )

      endpoints do
        base("https://graph.microsoft.com/v1.0")

        endpoint :read do
          path("/users")
        end
      end
    end

    actions do
      read :read do
        primary? true
        pagination(offset?: true, required?: false, countable: true)
      end
    end

    attributes do
      uuid_primary_key(:id, public?: true)
      attribute(:display_name, :string, public?: true)
      attribute(:email, :string, public?: true)
      attribute(:user_principal_name, :string, public?: true)
      attribute(:job_title, :string, public?: true)
      attribute(:department, :string, public?: true)
      attribute(:account_enabled, :boolean, public?: true)
      attribute(:created_date_time, :utc_datetime, public?: true)
    end
  end

  defmodule Group do
    use Ash.Resource,
      domain: AshJsonApiWrapper.ODataTest.Domain,
      data_layer: AshJsonApiWrapper.DataLayer,
      validate_domain_inclusion?: false

    json_api_wrapper do
      tesla(TestingTesla)
      dialect({AshJsonApiWrapper.Dialect.OData, in_operator: :or})

      endpoints do
        base("https://graph.microsoft.com/v1.0")

        endpoint :read do
          path("/groups")
        end
      end
    end

    actions do
      defaults([:read])
    end

    attributes do
      uuid_primary_key(:id, public?: true)
      attribute(:display_name, :string, public?: true)
      attribute(:description, :string, public?: true)
      attribute(:mail, :string, public?: true)
      attribute(:mail_enabled, :boolean, public?: true)
      attribute(:security_enabled, :boolean, public?: true)
      attribute(:group_types, {:array, :string}, public?: true)
      attribute(:created_date_time, :utc_datetime, public?: true)
    end
  end

  defmodule Application do
    use Ash.Resource,
      domain: AshJsonApiWrapper.ODataTest.Domain,
      data_layer: AshJsonApiWrapper.DataLayer,
      validate_domain_inclusion?: false

    json_api_wrapper do
      tesla(TestingTesla)
      dialect(AshJsonApiWrapper.Dialect.OData)

      endpoints do
        base("https://graph.microsoft.com/v1.0")

        endpoint :read do
          path("/applications")
        end
      end
    end

    actions do
      defaults([:read])
    end

    attributes do
      uuid_primary_key(:id, public?: true)
      attribute(:app_id, :uuid, public?: true)
      attribute(:display_name, :string, public?: true)
      attribute(:sign_in_audience, :string, public?: true)
      attribute(:created_date_time, :utc_datetime, public?: true)
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defp respond(body, status \\ 200), do: {:ok, %Tesla.Env{status: status, body: body}}

  # Runs the query and returns the query params that were sent.
  defp sent_params(query) do
    test = self()

    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      send(test, {:params, env.query})
      respond(~s({"value": []}))
    end)

    Ash.read!(query)
    assert_received {:params, params}
    params
  end

  defp sent_filter(query), do: sent_params(query)["$filter"]

  # Property names of an entity type in the metadata, including those of its base types.
  defp properties(entity_type) do
    [_, attributes, body] =
      Regex.run(~r/<EntityType Name="#{entity_type}"([^>]*)>(.*?)<\/EntityType>/s, @metadata)

    own = Regex.scan(~r/<Property Name="(\w+)"/, body, capture: :all_but_first)

    base =
      case Regex.run(~r/BaseType="graph\.(\w+)"/, attributes) do
        [_, base] -> properties(base)
        nil -> []
      end

    List.flatten(own) ++ base
  end

  test "every property the resources use exists in the Graph metadata" do
    for {resource, entity_type} <- [
          {User, "user"},
          {Group, "group"},
          {Application, "application"}
        ] do
      opts = AshJsonApiWrapper.DataLayer.Info.dialect_opts(resource)

      used =
        for name <- Ash.Resource.Info.attribute_names(resource) do
          AshJsonApiWrapper.Dialect.Naming.remote_name(
            name,
            opts[:property_case],
            opts[:properties]
          )
        end

      assert used -- properties(entity_type) == [], "#{entity_type}: #{inspect(used)}"
    end
  end

  test "filter, select, sort and limit become system query options" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn env, _ ->
      assert env.method == :get
      assert env.url == "https://graph.microsoft.com/v1.0/users"
      assert {"ConsistencyLevel", "eventual"} in env.headers

      assert env.query == %{
               "$filter" => "accountEnabled eq true and startswith(displayName,'A')",
               "$select" => "id,displayName,mail",
               "$orderby" => "displayName asc",
               "$top" => 2,
               "$count" => "true"
             }

      respond(@users_page_1)
    end)

    assert [adele, alex] =
             User
             |> Ash.Query.filter(
               account_enabled == true and string_starts_with(display_name, "A")
             )
             |> Ash.Query.select([:display_name, :email])
             |> Ash.Query.sort(display_name: :asc)
             |> Ash.Query.limit(2)
             |> Ash.read!()

    assert adele.display_name == "Adele Example"
    assert adele.email == "adele@example.com"
    assert adele.id == "6e7b768e-07e2-4810-8459-485f84f8f204"
    assert alex.display_name == "Alex Sample"
  end

  test "literals are encoded by type" do
    assert sent_filter(Ash.Query.filter(User, display_name == "O'Brien")) ==
             "displayName eq 'O''Brien'"

    assert sent_filter(Ash.Query.filter(User, id == "6e7b768e-07e2-4810-8459-485f84f8f204")) ==
             "id eq 6e7b768e-07e2-4810-8459-485f84f8f204"

    assert sent_filter(Ash.Query.filter(User, created_date_time >= ^~U[2024-01-01 00:00:00Z])) ==
             "createdDateTime ge 2024-01-01T00:00:00Z"

    assert sent_filter(Ash.Query.filter(User, is_nil(email))) == "mail eq null"
    assert sent_filter(Ash.Query.filter(User, not is_nil(email))) == "not (mail eq null)"
  end

  test "operators and boolean groups" do
    assert sent_filter(Ash.Query.filter(User, department in ["Sales"])) ==
             "department in ('Sales')"

    assert sent_filter(Ash.Query.filter(User, department != "Sales")) == "department ne 'Sales'"

    assert sent_filter(Ash.Query.filter(User, contains(job_title, "Lead"))) ==
             "contains(jobTitle,'Lead')"

    assert sent_filter(Ash.Query.filter(User, string_ends_with(email, "@example.com"))) ==
             "endswith(mail,'@example.com')"

    filter =
      sent_filter(
        Ash.Query.filter(
          User,
          account_enabled == true and (department == "A" or job_title == "B")
        )
      )

    assert filter in [
             "accountEnabled eq true and (department eq 'A' or jobTitle eq 'B')",
             "(department eq 'A' or jobTitle eq 'B') and accountEnabled eq true"
           ]

    assert sent_filter(Ash.Query.filter(User, not (department == "A" or job_title == "B"))) ==
             "not (department eq 'A' or jobTitle eq 'B')"
  end

  test "`in` can be sent as `eq` joined with `or`" do
    filter = sent_filter(Ash.Query.filter(Group, display_name in ["A", "B"]))

    assert filter in [
             "(displayName eq 'A' or displayName eq 'B')",
             "(displayName eq 'B' or displayName eq 'A')"
           ]
  end

  test "follows @odata.nextLink" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      if String.contains?(env.url, "$skiptoken") do
        assert env.query == %{}
        respond(@users_page_2)
      else
        respond(@users_page_1)
      end
    end)

    assert ["Adele Example", "Alex Sample", "Avery Placeholder"] =
             User |> Ash.read!() |> Enum.map(& &1.display_name)
  end

  test "stops following pages once the limit is reached" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn _, _ -> respond(@users_page_1) end)

    assert [_, _] = User |> Ash.Query.limit(2) |> Ash.read!()
  end

  test "page counts use @odata.count" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      case env.query do
        %{"$top" => 1, "$count" => "true"} = query ->
          refute Map.has_key?(query, "$skip")
          respond(@users_page_2)

        %{"$top" => 3, "$skip" => 1} ->
          respond(@users_page_2)
      end
    end)

    page = Ash.read!(User, page: [limit: 2, offset: 1, count: true])
    assert page.count == 3
    assert [%{display_name: "Avery Placeholder", account_enabled: false}] = page.results
  end

  test "page counts are only supported with `count: true`" do
    refute AshJsonApiWrapper.DataLayer.can?(Group, {:query_aggregate, :count})
    assert AshJsonApiWrapper.DataLayer.can?(User, {:query_aggregate, :count})
  end

  test "groups and applications" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 2, fn env, _ ->
      case env.url do
        "https://graph.microsoft.com/v1.0/groups" -> respond(@groups)
        "https://graph.microsoft.com/v1.0/applications" -> respond(@applications)
      end
    end)

    assert [engineering, building] = Ash.read!(Group)
    assert engineering.group_types == ["Unified"]
    assert engineering.mail_enabled
    assert building.group_types == []
    assert building.security_enabled

    assert [app] = Ash.read!(Application)
    assert app.app_id == "631a96bc-a705-4eda-9f99-fdaf9f54f6a2"
    assert app.sign_in_audience == "AzureADMyOrg"
    assert app.created_date_time == ~U[2024-04-08 07:20:00Z]
  end

  test "filters OData cannot express are rejected before any request" do
    expect(AshJsonApiWrapper.MockAdapter, :call, 0, fn _, _ -> :unreachable end)

    assert {:error, _} = User |> Ash.Query.filter(display_name == department) |> Ash.read()
    assert {:error, _} = User |> Ash.Query.filter(string_length(display_name) > 3) |> Ash.read()
  end

  test "OData errors are returned as errors" do
    expect(AshJsonApiWrapper.MockAdapter, :call, fn _, _ -> respond(@error, 400) end)

    assert {:error, error} = Ash.read(User)
    assert Exception.message(error) =~ "Request_UnsupportedQuery"
  end
end
