# Antigravity Rules for holoscape

<!-- AUTO-GENERATED from .agentsync/rules/ - Do not edit directly -->
<!-- Run: uv run $TOOLS_ROOT/agentsync/sync_rules.py holoscape -->

# AGENTS.md - Source of Truth for AI Agents

## 🎯 Project Overview

This document serves as the central repository for information regarding AI Agents developed within this project. It outlines the project's goals, technical specifications, execution guidelines, and critical constraints to ensure consistency and quality across all agent implementations. This document is intended to be a living document, updated as the project evolves.

{project_description}

## 🛠 Tech Stack

- Language: {language} (e.g., Python)
- Frameworks: {frameworks} (e.g., Langchain, Transformers, OpenAI API)
- AI Strategy: {ai_strategy} (e.g., Reinforcement Learning, Natural Language Processing, Knowledge Graph Reasoning)

## 📋 Definition of Done (DoD)

The following criteria must be met before an agent implementation is considered complete:

- [ ] Code is documented with type hints.
- [ ] Technical changes are logged to `project-tracker/data/WARDEN_LOG.yaml`.
- [ ] `00_Index_*.md` is updated with recent activity.
- [ ] Code validated (no hardcoded paths, no secrets exposed).
- [ ] Code review completed (if significant architectural changes).
- [ ] [Project-specific DoD item] (e.g., Agent achieves target performance metric)

**Explanation of DoD Items:**

*   **Code Documentation:**  Ensures code is understandable and maintainable. Type hints are crucial for static analysis and preventing runtime errors.
*   **WARDEN_LOG.yaml:**  Provides a chronological record of significant changes, facilitating debugging and auditing.
*   **00_Index_*.md:**  Keeps the project index up-to-date, improving discoverability of new agents and features.
*   **Code Validation:**  Prevents common errors such as exposing sensitive information or creating environment-specific dependencies.  The `validate_project.py` script should perform these checks.
*   **Code Review:**  Ensures code quality, adherence to standards, and knowledge sharing.
*   **Project-Specific DoD:**  Allows for criteria specific to the agent's purpose and performance requirements.

## 🚀 Execution Commands

- Environment: `{venv_activation}` (e.g., `source .venv/bin/activate`)
- Run: `{run_command}` (e.g., `python ./agents/my_agent.py --config config.yaml`)
- Test: `{test_command}` (e.g., `pytest ./tests/agents/test_my_agent.py`)

**Example Usage:**

To run an agent named `my_agent.py` with a configuration file `config.yaml`, you would first activate the virtual environment and then execute the run command.  Similarly, the test command would execute the unit tests for that agent.

## ⚠️ Critical Constraints

Adherence to these constraints is crucial for security, portability, and maintainability.

- NEVER hard-code API keys, secrets, or credentials in script files. Use `.env` and `os.getenv()`.
- NEVER use absolute paths (e.g., machine-specific paths). ALWAYS use relative paths or `PROJECT_ROOT` env var.
- ALWAYS run validation before considering work complete: `python "./scripts/validate_project.py" [project-name]`
- {constraint_1} (e.g., Agents must adhere to rate limits imposed by external APIs.)
- {constraint_2} (e.g., Agents should be designed to be robust to unexpected input.)

**Explanation of Constraints:**

*   **Secrets Management:**  Hardcoding secrets is a major security vulnerability.  Using `.env` files and `os.getenv()` allows for secure storage and retrieval of sensitive information.  Consider using a secrets management tool like Doppler.
*   **Path Management:**  Absolute paths make code non-portable.  Relative paths or environment variables ensure that the code works correctly across different environments.
*   **Validation:**  The `validate_project.py` script should perform checks for hardcoded secrets, absolute paths, and other common errors.  This helps to prevent these issues from being introduced into the codebase.

**Code Review Standards:** See `./REVIEWS_AND_GOVERNANCE_PROTOCOL.md` for full review process.

## 📖 Reference Links

- `00_Index_*.md`
- [[Project Philosophy]]

## Agent Examples

This section provides links to specific agent implementations within the project.

*   [[agents/example_agent_1/README.md]] - Description of Example Agent 1
*   [[agents/example_agent_2/README.md]] - Description of Example Agent 2
