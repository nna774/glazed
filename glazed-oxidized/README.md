# glazed-oxidized

Runs [Oxidized](https://github.com/ytti/oxidized) model files as [glazed](https://github.com/sorah/glazed) dialects. A node whose dialect is `oxidized_<model>` runs the model file `<model>.rb`, such as `oxidized_eos` for `eos.rb`. Each model file is loaded into its own [Ruby::Box](https://docs.ruby-lang.org/en/4.0/Ruby/Box.html), so whatever it defines at the top level, patches into core classes or sets as globals stays out of glazed.

Requires Ruby 4.0 or later, started with `RUBY_BOX=1`, and Oxidized model files from the `oxidized` gem or a directory.

```jsonc
// glazed.json
{"requires": ["glazed/oxidized"], ...}
```

```
RUBY_BOX=1 bundle exec glazed run -c glazed.json
```

The substitutions in a model's `cmd :secret` blocks become the dialect's sensitive patterns, so the `redact` step hides the secrets the model knows about. See [docs/oxidized-shim.md](../docs/oxidized-shim.md) for usage, node variables, secrets and limitations.
