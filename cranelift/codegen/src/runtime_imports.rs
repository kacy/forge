use crate::CompileError;
use cranelift::prelude::*;
use cranelift_module::{FuncId, Linkage, Module};
use cranelift_object::ObjectModule;
use std::collections::HashMap;

struct RuntimeDecl {
    key: &'static str,
    symbol: &'static str,
    params: &'static [Type],
    returns: &'static [Type],
}

include!(concat!(env!("OUT_DIR"), "/runtime_table.rs"));

fn declare_runtime_function(
    module: &mut ObjectModule,
    name: &str,
    params: &[Type],
    returns: &[Type],
) -> Result<FuncId, CompileError> {
    let mut sig = module.make_signature();

    for param in params {
        sig.params.push(AbiParam::new(*param));
    }

    for ret in returns {
        sig.returns.push(AbiParam::new(*ret));
    }

    let func_id = module
        .declare_function(name, Linkage::Import, &sig)
        .map_err(|e| CompileError::ModuleError(e.to_string()))?;

    Ok(func_id)
}

pub fn declare_runtime_functions(
    module: &mut ObjectModule,
) -> Result<HashMap<String, FuncId>, CompileError> {
    let mut funcs = HashMap::new();
    let mut declared: HashMap<String, FuncId> = HashMap::new();

    for decl in ABI_RUNTIME_FUNCTIONS {
        let fid = if let Some(&existing) = declared.get(decl.symbol) {
            existing
        } else {
            let fid = declare_runtime_function(module, decl.symbol, decl.params, decl.returns)?;
            declared.insert(decl.symbol.to_string(), fid);
            fid
        };
        funcs.insert(decl.key.to_string(), fid);
    }

    for decl in COMPAT_RUNTIME_FUNCTIONS {
        let fid = if let Some(&existing) = declared.get(decl.symbol) {
            existing
        } else {
            let fid = declare_runtime_function(module, decl.symbol, decl.params, decl.returns)?;
            declared.insert(decl.symbol.to_string(), fid);
            fid
        };
        funcs.insert(decl.key.to_string(), fid);
    }

    Ok(funcs)
}
