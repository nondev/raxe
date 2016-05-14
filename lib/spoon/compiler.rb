require "spoon/util/namespace"

module Spoon
  class Compiler
    attr_reader :name
    attr_reader :scope
    attr_reader :class_scope
    attr_reader :instance_scope
    attr_reader :class_names

    def initialize(path = "main")
      basename = File.basename(path, ".*")
      @name = basename.split('_').collect!{ |w| w.capitalize }.join
      @class_names = []

      @nodes = {
        :root => Root,
        :block => Block,
        :closure => Closure,
        :if => If,
        :for => For,
        :while => While,
        :assign => Assign,
        :op => Operation,
        :call => Call,
        :new => New,
        :return => Return,
        :import => Import,
        :param => Param,
        :value => Value,
        :table => Table
      }

      @scope = Spoon::Util::Namespace.new
      @class_scope = Spoon::Util::Namespace.new
      @instance_scope = Spoon::Util::Namespace.new
    end

    def in_class
      @class_names.length > 1
    end

    def compile(node, parent = nil, tab = "")
      @nodes[node.type].new(self, node, parent, tab).compile.to_s
    end
  end

  class Base
    attr_reader :tab
    attr_reader :node
    attr_reader :parent

    def initialize(compiler, node, parent, tab)
      @compiler = compiler
      @node = node
      @parent = parent
      @content = ""
      @tab = tab
    end

    def compile
      @content
    end

    def compile_next(node)
      @compiler.compile(node, self, @tab)
    end

    def compile_str(str)
      if str.start_with? "'"
        str
      else
        str.gsub!("-", "_") || str
      end
    end
  end

  class Root < Base
    def initialize(compiler, node, parent, tab)
      super
      @tab = "    "
    end

    def compile
      @compiler.scope.add
      @compiler.scope.push @compiler.name
      @compiler.class_names.push @compiler.name
      @compiler.class_scope.add
      @compiler.instance_scope.add

      imports = ""

      @node.children.each do |child|
        if child.type == :import
          imports << compile_next(child) << ";\n"
        else
          @content << @tab << compile_next(child) << ";\n"
        end
      end

      class_variables = ""

      @compiler.class_scope.get.each do |key, value|
        class_variables << "  static var #{key};\n"
      end

      instance_variables = ""

      @compiler.instance_scope.get.each do |key, value|
        class_variables << "  var #{key};\n"
      end

      @content = "class #{@compiler.name} {\n#{class_variables}#{instance_variables}  static public function main() {\n#{@content}"
      @content = "#{imports}#{@content}"
      @content << "  }\n"
      @content << "}"

      @compiler.scope.pop
      @compiler.class_scope.pop
      @compiler.instance_scope.pop
      @compiler.class_names.pop
      super
    end
  end

  class Block < Base
    def initialize(compiler, node, parent, tab)
      super
      @tab = tab + "  "
    end

    def compile
      @content << "{\n"

      @node.children.each do |child|
        @content << @tab << compile_next(child) << ";\n"
      end

      @content << @parent.tab << "}"
      super
    end
  end

  class Assign < Base
    @@assign_counter = 0

    def compile
      children = @node.children.dup

      left = children.shift
      right = children.shift

      if left.option :is_array
        assign_name = "__assign#{@@assign_counter}"
        @content << "var #{assign_name} = #{compile_next(right)};\n"
        @@assign_counter += 1

        left.children.each_with_index do |child, index|
          child_name = compile_next(child)
          @content << @parent.tab
          scope_name(child)
          @content << "#{child_name} = #{assign_name}[#{index}]"
          @content << ";\n" unless left.children.last == child
        end
      elsif left.option :is_hash
        assign_name = "__assign#{@@assign_counter}"
        @content << "var #{assign_name} = #{compile_next(right)};\n"
        @@assign_counter += 1

        left.children.each do |child|
          child_children = child.children.dup
          child_children.shift
          child_alias_node = child_children.shift
          child_alias = compile_next(child_alias_node)
          child_name = compile_next(child_children.shift)
          @content << @parent.tab
          scope_name(child_alias_node)
          @content << "#{child_alias} = #{assign_name}.#{child_name}"
          @content << ";\n" unless left.children.last == child
        end
      else
        @content << "(" if @parent.node.type == :op
        @content << scope_name(left)
        @content << " = " << compile_next(right)
        @content << ")" if @parent.node.type == :op
      end

      super
    end

    def scope_name(node)
      if node.type == :value
        content = compile_next(node)
        if @compiler.scope.push content
          @content << "var "
        end
      elsif node.type == :self || left.type == :this
        content = compile_next(node)
        name = compile_next(node.children.first)

        if node.type == :self
          raise ArgumentError, 'Self call cannot be used outside of class' unless @compiler.in_class
          @compiler.class_scope.push name
        elsif node.type == :this
          if @compiler.in_class
            @compiler.instance_scope.push name
          else
            @compiler.class_scope.push name
          end
        end
      end

      content
    end
  end

  class Operation < Base
    def compile
      children = @node.children.dup
      operator = children.shift.to_s

      @content << "(" if @parent.node.type == :op

      case @node.option :operation
      when :infix
        @content << compile_next(children.shift)
        @content << " #{operator} "
        @content << compile_next(children.shift)
      when :prefix
        @content << operator
        @content << compile_next(children.shift)
      when :suffix
        @content << compile_next(children.shift)
        @content << operator
      end

      @content << ")" if @parent.node.type == :op

      super
    end
  end

  class Value < Base
    def compile
      children = @node.children.dup

      children.each do |child|
        if child.is_a?(String) || child.is_a?(Fixnum) || [true, false].include?(child)
          @content << compile_str(child.to_s)
        else
          if @node.option :is_self
            raise ArgumentError, 'Self call cannot be used outside of class' unless @compiler.in_class
            @content << "#{@compiler.class_names.last}."
          elsif @node.option :is_this
            @content << (@compiler.in_class ?  "this." : "#{@compiler.class_names.last}.")
          end

          @content << compile_next(child)
        end

        @content << " + " unless children.last == child
      end

      super
    end
  end

  class Param < Base
    def compile
      children = @node.children.dup
      @content << compile_next(children.shift)
      @content << " = " << compile_next(children.shift) unless children.empty?
      super
    end
  end

  class Table < Base
    def compile
      children = @node.children.dup
      @content << (@node.option(:is_array) ? "[" : "{")

      children.each do |child|
        @content << compile_next(child)
        @content << ", " unless children.last == child
      end

      @content << (@node.option(:is_array) ? "]" : "}")
      super
    end
  end

  class New < Base
    def compile
      children = @node.children.dup
      @content << "new "
      @content << compile_next(children.shift)
      @content << "("

      children.each do |child|
        @content << compile_next(child)
        @content << ", " unless children.last == child
      end

      @content << ")"
      super
    end
  end

  class Call < Base
    def compile
      children = @node.children.dup
      @content << compile_next(children.shift)
      @content << "("

      children.each do |child|
        @content << compile_next(child)
        @content << ", " unless children.last == child
      end

      @content << ")"
      super
    end
  end

  class Import < Base
    def compile
      children = @node.children.dup

      @content << "import "

      children.each do |child|
        @content << compile_next(child)
        @content << "." unless children.last == child
      end

      super
    end
  end

  class Closure < Base
    def compile
      @compiler.scope.add

      children = @node.children.dup

      @content << "function ("

      if children.length > 1
        children.each do |child|
          name = child.children.first.to_s
          @compiler.scope.push name

          unless child == children.last
            @content << compile_next(child)
            @content << ", " unless child == children[children.length - 2]
          end
        end
      end

      @content << ") return "
      @content << compile_next(children.last)

      @compiler.scope.pop
      super
    end
  end

  class If < Base
    def compile
      children = @node.children.dup

      @content << "if (" << compile_next(children.shift) << ") "
      @content << compile_next(children.shift)
      @content << " else " << compile_next(children.shift) unless children.empty?
      super
    end
  end

  class For < Base
    def compile
      children = @node.children.dup

      @content << "for (" << compile_next(children.shift) << ") "
      @content << compile_next(children.shift)
      super
    end
  end

  class While < Base
    def compile
      children = @node.children.dup

      @content << "while (" << compile_next(children.shift) << ") "
      @content << compile_next(children.shift)
      super
    end
  end

  class Return < Base
    def compile
      children = @node.children.dup
      multi = children.length > 1
      @content << "return "
      @content << "[" if multi

      children.each do |child|
        @content << compile_next(child)
        @content << ", " unless children.last == child
      end

      @content << "]" if multi

      super
    end
  end
end
