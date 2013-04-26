// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'mirrors.dart';
import 'mirror_utils.dart';

const String inject = "inject";

class DefaultBinding<T> {
  final Module _module;
  final Type type;
  var boundTo;

  DefaultBinding(Module this._module, Type this.type);

  T get singleton {
    var binding = _module._getBinding(type);
    if (binding == null) binding = boundTo;
    if (binding == null) binding = type;
    if (binding is Type) {
      var mirror = reflectClass(binding);
      return _module._singleton(mirror.qualifiedName,
          () => _module._newFromTypeMirror(mirror));
    } else if (binding is Function) {
      return _module._singleton(type.toString(),
          () => _module._newFromClosureMirror(reflect(binding)));
    }
  }

  T newInstance() {
    var binding = _module._getBinding(type);
    if (binding == null) binding = boundTo;
    if (binding == null) binding = type;

    if (binding is Type) {
      var mirror = reflectClass(binding);
      return _module._newFromTypeMirror(mirror);
    } else if (binding is Function) {
      return _module._newFromClosureMirror(reflect(binding));
    }
  }

  DefaultBinding use(Type type) => _bindTo(type);

  DefaultBinding providedBy(Function f) => _bindTo(f);

  DefaultBinding _bindTo(dynamic boundTo) {
    this.boundTo = boundTo;
    return this;
  }
}

class OverrideBinding {
  final Module _module;
  final Type type;
  var boundTo;

  OverrideBinding(Module this._module, Type this.type);

  OverrideBinding to(binding) {
    _module._bindings[type] = binding;
  }
}

/**
 * A Module is a container of instances.
 */
abstract class Module {
  Module _parent;

  Map<Symbol, Object> _singletons = new Map<Symbol, Object>();
  Map<Type, dynamic> _bindings = new Map<Type, dynamic>();

  InstanceMirror _moduleMirror;

  Module() {
    _moduleMirror = reflect(this);
  }

  Module.childOf(Module parent) {
    this._parent = parent;
    _moduleMirror = reflect(this);
  }

  /**
   * Creates a child of this module that can have it's own binding overrides.
   */
  Module createChild() =>
        _moduleMirror.type.newInstance(new Symbol('childOf'), [this], null).reflectee;

  /**
   * Overrides an existing mutable binding, or defines a new binding, for
   * [type]. Non-mutable bindings (defined with abstract methods) are not
   * overriden. No error for attempting to override a non-mutable binding is
   * reported yet.
   *
   * Example:
   *
   *     class MyModule {
   *       Foo get foo => getByType(Foo).singleton;
   *     }
   *
   *     main() {
   *       var module = new MyModule();
   *       module.bind(Foo).to(SubclassOfFoo);
   *       assert(module.foo is SubclassOfFoo);
   *     }
   */
  OverrideBinding bind(Type type) => new OverrideBinding(this, type);

  /**
   * Defines the default for a mutable binding for a type in a module. Only call
   * this method in the module declaration. Returns a binder which has method
   * [newInstance] and getter [cingleton] to define the behavior of the binding.
   *
   * The binding defined here can be overridden by subsequent calls to [bind].
   *
   * Example:
   *
   *     class MyModule {
   *       Foo newFoo() => getByType(Foo).newInstance();
   *       Bar get get => getByType(Bar).singleton;
   *     }
   */
  DefaultBinding getByType(Type type) => new DefaultBinding(this, type);

  dynamic _getBinding(Type type) {
    if (_bindings.containsKey(type)) {
      return _bindings[type];
    } else if (_parent != null) {
      return _parent._getBinding(type);
    }
    return null;
  }

  /**
   * Get an instance with a Type named [typename].
   *
   * Searches through the members of the module to find one that's return type
   * equals [typename], then invokes the member, using this module to get
   * instances for constructor parameters, if necessary.
   */
  Object getInstanceOf(Type type) {
    return _newFromTypeMirror(reflectClass(type));
  }

  Object _getType(Symbol typename) {
    //TODO (adambender): Need to allow for injector to be injected, not module
    if (implements(_moduleMirror.type, typename, useSimple: true)) {
      return this;
    }
    for (var member in _moduleMirror.type.members.values) {
      if (member is VariableMirror) {
        if (implements(member.type, typename, useSimple: true)) {
          return _moduleMirror.getField(member.simpleName).reflectee;
        }
      } else if (member is MethodMirror) {
        if (implements(member.returnType, typename, useSimple: true)) {
          return _newFromTypeMirror(member.returnType);
        }
      }
    }
  }

  /**
   * Create a new instance with a type represented by [m], resolving
   * constructor dependencies.
   */
  Object _newFromTypeMirror(TypeMirror m) {
    if (m is ClassMirror) {
      // Choose contructor using @inject when we can
      MethodMirror ctor = (m.constructors.length == 1)
          ? m.constructors.values.first
          : m.constructors[''];
      if (ctor == null) {
        throw new ArgumentError("${m.qualifiedName} must have a no-arg constructor"
            " or a single constructor");
      }
      // resolve dependencies
      var pargs = ctor.parameters.map((p) =>
          _getType(p.type.qualifiedName)).toList();
      return m.newInstance(ctor.constructorName, pargs, null).reflectee;
    }
  }

  Object _newFromClosureMirror(ClosureMirror m) {
    var pargs = m.function.parameters.map((p) =>
        _getType(p.type.simpleName)).toList();
    return Function.apply(m.reflectee, pargs);
  }

  Object _singleton(Symbol typeName, InstanceMirror f()) {
    if (_singletons.containsKey(typeName)) {
      return _singletons[typeName];
    } else {
      var instance = f();
      _singletons[typeName] = instance;
      return instance;
    }
  }

  noSuchMethod(Invocation im) {
    var member = getMemberMirror(_moduleMirror.type, im.memberName);

    if (member is MethodMirror) {
      if (member.isGetter) {
        var typeName = member.returnType.qualifiedName;
        return _singleton(typeName,
            () => _newFromTypeMirror(member.returnType));
      } else {
        return _newFromTypeMirror(member.returnType);
      }
    }

    super.noSuchMethod(im);
  }
}
