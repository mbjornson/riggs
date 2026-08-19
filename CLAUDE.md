# CLAUDE.md

## Overview

Riggs is a PM-centric multi-agentic harness.

## Ruby Coding Standards

These are the rules all agents must follow when contributing to Riggs.

- Classes can be no longer than 100 lines of code.
- Methods can be no longer than 5 lines of code.
- Pass no more than 4 parameters into a method. Hash options are parameters.
- Controllers can instantiate only one object. Therefore, views can only know about one instance variable and views should only send messages to that object (@object.collaborator.value is not allowed).
- Avoid global variables.
- Limit dependencies of an object (entities an object depends on).
- Limit an object's dependents (entities that depend on an object).
- Prefer composition to inheritance.
- Avoid multiple assignments per line (`one, two = 1, 2`).
- Avoid ternary operators (`boolean ? true : false`). Use multi-line `if`
  instead to emphasize code branches.
- Prefer nested class and module definitions over the shorthand version
- Prefer `detect` over `find`.
- Prefer `select` over `find_all`.
- Prefer `map` over `collect`.
- Prefer `reduce` over `inject`.
- Prefer `&:method_name` to `{ |item| item.method_name }` for simple method
  calls.
- Use `%()` for single-line strings containing double-quotes that require
  interpolation.
- Use heredocs for multi-line strings.
- Avoid monkey-patching.
- Generate necessary [Bundler binstubs] for the project, such as `rake` and
  `rspec`, and add them to version control.
- Prefer classes to modules when designing functionality that is shared by
  multiple models.
- Avoid organizational comments (`# Validations`).
- Use empty lines around multi-line blocks.
- Avoid bang (!) method names. Prefer descriptive names.
- Use `?` suffix for predicate methods.
- Use `def self.method`, not `class << self`.
- Use `def` with parentheses when there are arguments.
- Avoid optional parameters. Does the method do too much?
- Order class methods above instance methods.
- Prefer `private` when indicating scope. Use `protected` only with comparison
  methods like `def ==(other)`, `def <(other)`, and `def >(other)`.
- Prefix unused variables or parameters with underscore (`_`).
- Name variables created by a factory after the factory (`user_factory` creates
  `user`).
- Suffix variables holding a factory with `_factory` (`user_factory`).
- Use a leading underscore when defining instance variables for memoization.
- Prefer method invocation over instance variables.
