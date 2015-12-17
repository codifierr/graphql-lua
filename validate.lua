local rules = require 'rules'

local visitors = {
  document = {
    enter = function(node, context)
      for _, definition in ipairs(node.definitions) do
        if definition.kind == 'fragmentDefinition' then
          context.fragmentMap[definition.name.value] = definition
        end
      end
    end,

    children = function(node, context)
      return node.definitions
    end,

    rules = { rules.uniqueFragmentNames, exit = { rules.noUnusedFragments } }
  },

  operation = {
    enter = function(node, context)
      table.insert(context.objects, context.schema.query)
      context.variableReferences = {}
    end,

    exit = function(node, context)
      table.remove(context.objects)
      context.variableReferences = nil
    end,

    children = function(node)
      return { node.selectionSet }
    end,

    rules = {
      rules.uniqueOperationNames,
      rules.loneAnonymousOperation,
      rules.directivesAreDefined,
      rules.variablesHaveCorrectType,
      rules.variableDefaultValuesHaveCorrectType,
      exit = {
        rules.variablesAreUsed
      }
    }
  },

  selectionSet = {
    children = function(node)
      return node.selections
    end,

    rules = { rules.unambiguousSelections }
  },

  field = {
    enter = function(node, context)
      local parentField = context.objects[#context.objects].fields[node.name.value]

      -- false is a special value indicating that the field was not present in the type definition.
      local field = parentField and parentField.kind or false

      table.insert(context.objects, field)
    end,

    exit = function(node, context)
      table.remove(context.objects)
    end,

    children = function(node)
      local children = {}

      if node.arguments then
        for i = 1, #node.arguments do
          table.insert(children, node.arguments[i])
        end
      end

      if node.selectionSet then
        table.insert(children, node.selectionSet)
      end

      return children
    end,

    rules = {
      rules.fieldsDefinedOnType,
      rules.argumentsDefinedOnType,
      rules.scalarFieldsAreLeaves,
      rules.compositeFieldsAreNotLeaves,
      rules.uniqueArgumentNames,
      rules.argumentsOfCorrectType,
      rules.requiredArgumentsPresent,
      rules.directivesAreDefined
    }
  },

  inlineFragment = {
    enter = function(node, context)
      local kind = false

      if node.typeCondition then
        kind = context.schema:getType(node.typeCondition.name.value) or false
      end

      table.insert(context.objects, kind)
    end,

    exit = function(node, context)
      table.remove(context.objects)
    end,

    children = function(node, context)
      if node.selectionSet then
        return {node.selectionSet}
      end
    end,

    rules = {
      rules.fragmentHasValidType,
      rules.fragmentSpreadIsPossible,
      rules.directivesAreDefined
    }
  },

  fragmentSpread = {
    enter = function(node, context)
      context.usedFragments[node.name.value] = true

      local fragment = context.fragmentMap[node.name.value]
      local fragmentType = context.schema:getType(fragment.typeCondition.name.value) or false

      table.insert(context.objects, fragmentType)

      if context.variableReferences then
        local function collectTransitiveVariables(node)
          if not node then return end

          if node.kind == 'selectionSet' then
            for _, selection in ipairs(node.selections) do
              collectTransitiveVariables(selection)
            end
          elseif node.kind == 'field' and node.arguments then
            for _, argument in ipairs(node.arguments) do
              collectTransitiveVariables(argument)
            end
          elseif node.kind == 'argument' then
            return collectTransitiveVariables(node.value)
          elseif node.kind == 'listType' or node.kind == 'nonNullType' then
            return collectTransitiveVariables(node.type)
          elseif node.kind == 'variable' then
            context.variableReferences[node.name.value] = node.name.value
          elseif node.kind == 'inlineFragment' then
            return collectTransitiveVariables(node.selectionSet)
          elseif node.kind == 'fragmentSpread' then
            local fragment = context.fragmentMap[node.name.value]
            return fragment and collectTransitiveVariables(fragment.selectionSet)
          end
        end

        collectTransitiveVariables(fragment.selectionSet)
      end
    end,

    rules = {
      rules.fragmentSpreadTargetDefined,
      rules.fragmentSpreadIsPossible,
      rules.directivesAreDefined
    }
  },

  fragmentDefinition = {
    enter = function(node, context)
      kind = context.schema:getType(node.typeCondition.name.value) or false
      table.insert(context.objects, kind)
    end,

    exit = function(node, context)
      table.remove(context.objects)
    end,

    children = function(node)
      return { node.selectionSet }
    end,

    rules = {
      rules.fragmentHasValidType,
      rules.fragmentDefinitionHasNoCycles,
      rules.directivesAreDefined
    }
  },

  argument = {
    enter = function(node, context)
      if context.variableReferences then
        local value = node.value
        while value.kind == 'listType' or value.kind == 'nonNullType' do
          value = value.type
        end

        if value.kind == 'variable' then
          context.variablesUsed[value.name.value] = true
        end
      end
    end,

    rules = { rules.uniqueInputObjectFields }
  }
}

return function(schema, tree)
  local context = {
    schema = schema,
    fragmentMap = {},
    operationNames = {},
    hasAnonymousOperation = false,
    usedFragments = {},
    objects = {},
    variableReferences = nil
  }

  local function visit(node)
    local visitor = node.kind and visitors[node.kind]

    if not visitor then return end

    if visitor.enter then
      visitor.enter(node, context)
    end

    if visitor.rules then
      for i = 1, #visitor.rules do
        visitor.rules[i](node, context)
      end
    end

    if visitor.children then
      local children = visitor.children(node)
      if children then
        for _, child in ipairs(children) do
          visit(child)
        end
      end
    end

    if visitor.rules and visitor.rules.exit then
      for i = 1, #visitor.rules.exit do
        visitor.rules.exit[i](node, context)
      end
    end

    if visitor.exit then
      visitor.exit(node, context)
    end
  end

  return visit(tree)
end
