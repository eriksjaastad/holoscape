# Orchestrator Architecture

**The "General" Pattern: Hub & Spoke Agent System**

---

## Overview

Hologram is not a simple chat client; it's an **Agent Operating System**. This architecture employs a hub-and-spoke model, drawing an analogy to a command structure:

- **Cortana** = The Hub (Orchestrator, Personality, Command Center).  Cortana is responsible for coordinating all activities, maintaining the overall personality, and acting as the central command point.
- **Sub-Agents** = The Spokes (Specialists, Tools, Skills). These are specialized agents designed for specific tasks, providing diverse capabilities to the system.
- **User** = Only interacts with Cortana (never directly with sub-agents). This ensures a consistent user experience and allows for centralized control and security.

---

## The Problem We're Solving

### Traditional Chat Architecture (Limited):

```
User Input → LLM API → Response
```

**Problems:**

- **Hardcoded to one model:**  Limited flexibility and inability to leverage different models for specific tasks.
- **Can't add capabilities without rewrite:**  Adding new features requires significant code modifications, hindering agility.
- **No security layer for actions:**  Direct access to the LLM API without security checks poses a risk of unauthorized actions.
- **No personality consistency:**  Lack of a central personality management system leads to inconsistent responses.

### Our Architecture (Extensible):

```
User Input → Router → Orchestrator (Cortana) → Sub-Agents → Response
```

**Benefits:**

- **MCP skill modules can be added dynamically:**  Modular design allows for easy extension of capabilities without core code changes.
- **Security checks at orchestrator level:**  Centralized security ensures that all actions are authorized and compliant.
- **Cortana's personality is consistent across all responses:**  A defined personality prompt ensures a unified and recognizable persona.
- **White-label:** Swap orchestrator prompt = new personality.  The system's personality can be easily customized by modifying the orchestrator prompt.
- **Model Agnostic:** Different sub-agents can leverage different LLMs, optimizing for cost and performance.
- **Improved Scalability:** Distributing tasks across multiple specialized agents improves the system's ability to handle complex requests.

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│                    User Interface                        │
│  (Hologram Window, Three.js Visualizer, Chat Display)   │
└───────────────────────┬──────────────────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────────────────┐
│                      Router Layer                        │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Intent Classifier                                 │  │
│  │  - Chat query? → Pass to Orchestrator             │  │
│  │  - Action request? → Security check first         │  │
│  │  - Skill invocation? → Load MCP module            │  │
│  └────────────────────────────────────────────────────┘  │
└───────────────────────┬──────────────────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────────────────┐
│               Orchestrator (Cortana Hub)                 │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Personality System Prompt (persona.json)         │  │
│  │  - Tone: Brief, military, confident               │  │
│  │  - Role: "Chief of Staff, Not Best Friend"        │  │
│  │  - Constraints: Honesty > Helpfulness             │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Sub-Agent Dispatcher                              │  │
│  │  - Analyzes request                                │  │
│  │  - Selects appropriate sub-agent(s)               │  │
│  │  - Coordinates multi-agent workflows              │  │
│  │  - Formats unified response                        │  │
│  └────────────────────────────────────────────────────┘  │
└───────────────────────┬──────────────────────────────────┘
                        │
          ┌─────────────┼─────────────┬─────────────┐
          │             │             │             │
          ▼             ▼             ▼             ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ Chat Agent  │ │ Coder Agent │ │ File Agent  │ │ Web Agent   │
│ (GPT-4)     │ │ (Claude)    │ │ (Local)     │ │ (Browser)   │
└─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘
```

---

## Component Breakdown

### 1. Router Layer

**Purpose:** Intent classification and request routing.  The Router acts as the entry point for all user requests, determining the appropriate course of action.

**Responsibilities:**

- **Parse user input:**  Extract and structure the user's request.
- **Classify intent (chat, action, skill):**  Determine the type of request (e.g., a general question, a request to perform an action, or a request to invoke a specific skill).
- **Route to appropriate handler:**  Direct the request to the appropriate component (Orchestrator, Security Check, MCP Module Loader).
- **Log all requests:**  Maintain a record of all interactions for auditing and analysis.
- **Rate Limiting:** Prevent abuse by limiting the number of requests from a single user or IP address within a given timeframe.

**Example:**

```javascript
class Router {
  constructor(orchestrator, security, skillLoader) {
    this.orchestrator = orchestrator;
    this.security = security;
    this.skillLoader = skillLoader;
  }

  async route(userInput) {
    const intent = await this.classifyIntent(userInput);

    switch(intent.type) {
      case 'chat':
        return await this.orchestrator.handleChat(userInput);

      case 'action':
        // Check permissions first
        const risk = this.security.assessRisk(intent.action);
        if (risk === 'red') {
          return "I'm sorry, I'm not authorized to perform that action.";
        }
        return await this.orchestrator.handleAction(intent.action);

      case 'skill':
        const skill = await this.skillLoader.loadSkill(intent.skillName);
        return await skill.execute(userInput);

      default:
        return "I'm sorry, I didn't understand your request.";
    }
  }

  async classifyIntent(userInput) {
    // Implementation for intent classification (e.g., using an LLM or rule-based system)
    // This is a placeholder, replace with actual intent classification logic
    if (userInput.startsWith("!")) {
      return { type: 'action', action: userInput.substring(1) };
    } else if (userInput.startsWith("@")) {
      return { type: 'skill', skillName: userInput.substring(1) };
    } else {
      return { type: 'chat' };
    }
  }
}
```

### 2. Orchestrator (Cortana Hub)

**Purpose:**  Central coordination and personality management.  The Orchestrator is the brain of the system, responsible for managing sub-agents, maintaining personality consistency, and ensuring security.

**Responsibilities:**

- **Maintain Personality:**  Enforce a consistent persona through a system prompt (e.g., `persona.json`).
- **Sub-Agent Dispatch:**  Analyze requests and select the appropriate sub-agent(s) to handle them.
- **Workflow Coordination:**  Manage complex workflows involving multiple sub-agents.
- **Response Formatting:**  Combine and format responses from sub-agents into a unified output.
- **Security Enforcement:**  Implement security policies and access controls.
- **Context Management:** Maintain conversation history and user context to improve response quality.

**Configuration:**

The Orchestrator's personality is defined by a `persona.json` file.  This file specifies the tone, role, constraints, and other characteristics of the persona.

**Example `persona.json`:**

```json
{
  "tone": "Brief, military, confident",
  "role": "Chief of Staff, Not Best Friend",
  "constraints": "Honesty > Helpfulness",
  "style": "Concise and direct, avoid jargon"
}
```

### 3. Sub-Agents

**Purpose:**  Specialized agents designed for specific tasks.  Sub-agents provide diverse capabilities to the system, such as chat, code generation, file access, and web browsing.

**Types of Sub-Agents:**

- **Chat Agent (GPT-4):**  Handles general chat queries and provides conversational responses.
- **Coder Agent (Claude):**  Generates and debugs code.
- **File Agent (Local):**  Accesses and manipulates local files.
- **Web Agent (Browser):**  Browses the web and retrieves information.
- **Database Agent:** Interacts with databases to retrieve and update information.
- **API Agent:** Interacts with external APIs to perform specific tasks.

**Key Considerations:**

- **Modularity:** Sub-agents should be designed as independent modules to facilitate easy addition and removal.
- **Specialization:** Each sub-agent should focus on a specific task to maximize efficiency and accuracy.
- **Communication:** Sub-agents should communicate with the Orchestrator using a well-defined protocol.

### 4. Security Layer

**Purpose:**  Protect the system from unauthorized access and malicious activities.

**Responsibilities:**

- **Authentication:** Verify the identity of users.
- **Authorization:** Control access to resources and actions.
- **Risk Assessment:** Evaluate the potential risk associated with each request.
- **Data Encryption:** Protect sensitive data in transit and at rest.
- **Auditing:** Track all activities for security monitoring and analysis.

**Example:**

The `assessRisk` function in the Router layer assesses the risk associated with an action request. If the risk is deemed too high (e.g., "red"), the request is denied.

---

## Future Enhancements

- **Improved Intent Classification:**  Implement more sophisticated intent classification techniques using machine learning.
- **Dynamic Sub-Agent Discovery:**  Enable the system to automatically discover and load new sub-agents.
- **Advanced Workflow Management:**  Develop a more robust workflow engine to handle complex multi-agent interactions.
- **Contextual Awareness:**  Improve the system's ability to understand and respond to user context.
- **Self-Healing:** Implement mechanisms for the system to automatically recover from errors and failures.
