---
name: vein
description: "Use this skill when working with the vein issue tracker CLI. This is the primary way to interact with tasks when not using the MCP server (vein serve)."
metadata:
  managed-by: usage-rules
---

## Vein CLI Usage

`vein` is an agent-focused issue tracker backed by Vikunja. It can run as an MCP server (`vein serve`) or be used directly via command line.

### Workflow Commands

```sh
# List tasks ready to be worked on (Todo bucket)
vein list-ready

# List tasks currently in progress
vein list-in-progress

# List completed tasks
vein list-done

# List and search all tasks across buckets
vein list-tasks
vein list-tasks --search "keyword"
vein list-tasks --filter "priority >= 3"

# Get full details of a task by index or identifier
vein get-task <index|identifier>
```

### Task Lifecycle

```sh
# Claim a task (moves to In Progress)
vein claim <index|identifier>

# Mark a task as done
vein complete <index|identifier>

# Update a task's title, description, or priority
vein update-task <index|identifier> --title "New Title" --description "New description" --priority high

# Add a comment to a task
vein comment <index|identifier> "Comment text"
```

### Task Management

```sh
# Create a new task
vein create-task "Task Title" --description "Description" --priority urgent

# Labels
vein list-labels
vein create-label "label-name" --color "#ff0000"
vein add-label <task> "label-name"

# Relations
vein add-relation <task1> <task2> <relation_type>
```

### Discovery

```sh
# List available projects
vein list-projects

# List views for a project
vein list-project-views --project <id>

# List buckets for a view
vein list-project-view-buckets --project <id> --view <id>
```

### Interactive TUI

```sh
# Launch the interactive kanban board
vein board
```

### Task Identifiers

Tasks can be referenced by:
- Index: `3` or `#3`
- Identifier: `VEIN-3`
