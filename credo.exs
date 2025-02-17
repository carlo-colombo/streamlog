#! /usr/bin/env elixir

Mix.install([
  :credo
])

System.argv()
|> Credo.CLI.main()
