# Skill Maintenance

The `new-installer` skill at `.claude/skills/new-installer/` provides a guided workflow for scaffolding new installer scripts from the project's templates.

## Structure

```
.claude/skills/new-installer/
├── SKILL.md                           # Workflow, conventions, checklist
└── references/
    ├── template-binary.sh             # Binary app template
    ├── template-python.sh             # Python/uv template
    ├── template-docker.sh             # Docker Compose template
    ├── template-subdomain.sh          # Subdomain/subfolder template
    ├── template-multiinstance.sh      # Multi-instance template
    ├── coding-standards.md            # Enforced standards
    └── maintenance-checklist.md       # Post-creation todos
```

## Updating References

The skill bundles snapshots of templates and docs. When the source files change, sync the references:

```bash
# Sync all templates
cp templates/template-*.sh .claude/skills/new-installer/references/

# Sync docs
cp docs/coding-standards.md .claude/skills/new-installer/references/
cp docs/maintenance-checklist.md .claude/skills/new-installer/references/
```

## When to Update

Update the skill references whenever:

- A template in `templates/` is modified
- `docs/coding-standards.md` changes
- `docs/maintenance-checklist.md` changes
- A new template type is added (also update `SKILL.md` to reference it)

## Editing the Skill

The `SKILL.md` file controls the skill's behavior (workflow steps, conventions, checklist). Edit it directly at `.claude/skills/new-installer/SKILL.md`.

Key sections:
- **Template Types** table - lists available templates
- **Gather Requirements** - questions asked per template type
- **Generate the Script** - replacement rules and coding conventions
- **Post-Creation Checklist** - follow-up tasks from maintenance checklist
- **Template-Specific Notes** - per-type gotchas and patterns
