package macros;

#if (macro && MODS_ALLOWED)
import haxe.macro.Context;
import haxe.macro.Compiler;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
#end

/**
 * Compile-time rewrite that routes every `Type.resolveClass(name)` call
 * inside the `crowplexus.hscript` package (hscript-iris) through
 * `backend.ModSecurity.safeResolveClass(name)`. This means a mod's
 * HScript can't reach the ModSecurity class via `import` or `new` either,
 * since iris's import handler (`Tools.getClass`), constructor evaluator
 * (`Interp.cnew`) and exposed `Type` proxy (`proxy.ProxyType.resolveClass`)
 * all funnel through `Type.resolveClass` -- which we now intercept.
 *
 * Wired in via `--macro macros.PatchIris.patch()` in Project.xml.
 */
class PatchIris {
	#if (macro && MODS_ALLOWED)
	public static function patch():Void {
		// Tag every class in the iris package tree with our build macro.
		Compiler.addGlobalMetadata("crowplexus.hscript", "@:build(macros.PatchIris.buildPatch())");
	}

	public static function buildPatch():Array<Field> {
		final fields = Context.getBuildFields();
		for (f in fields) {
			switch (f.kind) {
				case FFun(fn):
					if (fn.expr != null) fn.expr = rewrite(fn.expr);
				case FVar(_, e) | FProp(_, _, _, e):
					if (e != null) {
						switch (f.kind) {
							case FVar(t, _): f.kind = FVar(t, rewrite(e));
							case FProp(g, s, t, _): f.kind = FProp(g, s, t, rewrite(e));
							default:
						}
					}
				default:
			}
		}
		return fields;
	}

	static function rewrite(e:Expr):Expr {
		if (e == null) return e;
		return switch (e.expr) {
			// Match Type.resolveClass(arg) -- both bare and via std.Type.
			case ECall({expr: EField({expr: EConst(CIdent("Type"))}, "resolveClass")}, args) if (args.length == 1):
				final arg = rewrite(args[0]);
				macro backend.ModSecurity.safeResolveClass($arg);
			default:
				ExprTools.map(e, rewrite);
		}
	}
	#end
}
