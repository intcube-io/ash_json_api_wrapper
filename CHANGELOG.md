<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## Unreleased

### Features

- Pluggable query dialects: the `AshJsonApiWrapper.QueryDialect` behaviour decides which
  filters, sorts and features a read supports, how it becomes requests, and how records, totals
  and next pages are read from responses. Resources pick one with `dialect`. Today's behaviour is
  the default `AshJsonApiWrapper.Dialect.Simple`. Page counts work for dialects that report a
  total. ([#7](https://github.com/intcube-io/ash_json_api_wrapper/issues/7))
- Cube.js dialect, `AshJsonApiWrapper.Dialect.CubeJs`.
  ([#1](https://github.com/intcube-io/ash_json_api_wrapper/issues/1))
- OData v4 dialect, `AshJsonApiWrapper.Dialect.OData`.
  ([#2](https://github.com/intcube-io/ash_json_api_wrapper/issues/2))
- Resource generator: `POST` query endpoints become reads, response wrappers are unwrapped, types
  follow `format`, `nullable`, enums and arrays, and `mix ash_json_api_wrapper.gen.resources`
  writes the resources to files. Endpoints get a `method` option.
  ([#3](https://github.com/intcube-io/ash_json_api_wrapper/issues/3))
- Generator overrides (`primary_key`, `skip`, `rename`, `filterable`, `relationships`) in the
  config or as `x-ash-*` extensions in the spec. Fields get `filter_operators`.
  ([#4](https://github.com/intcube-io/ash_json_api_wrapper/issues/4))
- `AshJsonApiWrapper.Tesla.BearerToken`: bearer tokens from a token endpoint, cached, refreshed
  before they expire, shared by concurrent requests, and renewed once on `401`.
  ([#5](https://github.com/intcube-io/ash_json_api_wrapper/issues/5))

### Bug Fixes

- Simple dialect: a handled filter combined with another one using `and` no longer turns the
  rest of the filter into `false`; get endpoint filters inside `and` keep their endpoint; the
  first value of a list or CSV list is no longer added twice; an `or` is only moved into a list
  when both sides can be.
- Headers from the query context and from paginators are sent, and a body set with
  `AshJsonApiWrapper.set_body_param/3` reaches read requests.
- A `false` filter returns no records instead of an invalid return value.
