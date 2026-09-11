use serde::{Deserialize, Serialize};
use wasm_memory::{
    ContainerVariant, ContainerVariantType, FunctionType, FunctionValue, WasmFunctionCall,
};

use super::runner::RunnerError;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq, sqlx::Type)]
#[serde(rename_all = "lowercase")]
#[sqlx(type_name = "TEXT", rename_all = "lowercase")]
pub enum Language {
    #[default]
    Cpp,
    Rust,
}

impl Language {
    pub fn route(self) -> &'static str {
        match self {
            Self::Cpp => "c++",
            Self::Rust => "rust",
        }
    }

    pub fn fuel_limit(self, fuel: Option<i64>) -> Option<i64> {
        match self {
            Self::Cpp => fuel,
            // ponytail: initial scalar-only allowance; calibrate per problem if languages expand.
            Self::Rust => fuel.map(|fuel| fuel.saturating_mul(4).clamp(100_000, 1 << 48)),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct RustSignature {
    name: String,
    arguments: Vec<&'static str>,
    result: &'static str,
}

fn unsupported() -> RunnerError {
    RunnerError::UnsupportedSignature {
        message: "Rust supports only scalar i32 and i64 arguments and results. All tests must use one function signature.".into(),
    }
}

impl RustSignature {
    pub fn from_calls<'a>(
        calls: impl IntoIterator<Item = &'a WasmFunctionCall>,
    ) -> Result<Self, RunnerError> {
        let mut signature = None;
        for call in calls {
            let mut chars = call.name.chars();
            if !matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
                || !chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
                || matches!(
                    call.name.as_str(),
                    "_" | "self" | "Self" | "super" | "crate"
                )
            {
                return Err(unsupported());
            }
            let current = Self {
                name: call.name.clone(),
                arguments: call
                    .arguments
                    .iter()
                    .map(|argument| match argument {
                        FunctionValue::Int(ContainerVariant::Single(_)) => Ok("i32"),
                        FunctionValue::Long(ContainerVariant::Single(_)) => Ok("i64"),
                        _ => Err(unsupported()),
                    })
                    .collect::<Result<_, _>>()?,
                result: match call.return_type {
                    FunctionType::Int(ContainerVariantType::Single) => "i32",
                    FunctionType::Long(ContainerVariantType::Single) => "i64",
                    _ => return Err(unsupported()),
                },
            };
            if signature
                .as_ref()
                .is_some_and(|previous| previous != &current)
            {
                return Err(unsupported());
            }
            signature = Some(current);
        }
        signature.ok_or_else(unsupported)
    }

    fn parameters(&self) -> String {
        self.arguments
            .iter()
            .enumerate()
            .map(|(i, ty)| format!("arg{i}: {ty}"))
            .collect::<Vec<_>>()
            .join(", ")
    }

    pub fn template(&self) -> String {
        format!(
            "fn r#{}({}) -> {} {{\n    // Return the answer.\n    0\n}}\n",
            self.name,
            self.parameters(),
            self.result
        )
    }

    pub fn wrapper(&self) -> String {
        let arguments = (0..self.arguments.len())
            .map(|i| format!("arg{i}"))
            .collect::<Vec<_>>()
            .join(", ");
        // An unnamed scope cannot collide with a user's helper name.
        format!("include!(\"implementation.rs\");\nconst _: () = {{\n#[export_name = \"acm_entry\"]\npub extern \"C\" fn __acm_entry({}) -> {} {{ crate::r#{}({arguments}) }}\n}};\n", self.parameters(), self.result, self.name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call() -> WasmFunctionCall {
        WasmFunctionCall::new(
            "add",
            vec![FunctionValue::Int(ContainerVariant::Single(2))],
            FunctionType::Long(ContainerVariantType::Single),
        )
    }

    #[test]
    fn rust_signatures_validate_every_call_and_identifier() {
        let a = call();
        let signature = RustSignature::from_calls([&a]).unwrap();
        assert!(signature.template().contains("fn r#add(arg0: i32) -> i64"));
        assert!(signature.wrapper().contains("export_name = \"acm_entry\""));
        let mut b = call();
        b.arguments[0] = FunctionValue::Int(ContainerVariant::List(vec![1]));
        assert!(RustSignature::from_calls([&a, &b]).is_err());
        b = call();
        b.name = "other".into();
        assert!(RustSignature::from_calls([&a, &b]).is_err());
        b.name = "add); injected".into();
        assert!(RustSignature::from_calls([&b]).is_err());
        assert!(RustSignature::from_calls([]).is_err());
        for ty in [
            FunctionType::String(ContainerVariantType::Single),
            FunctionType::Int(ContainerVariantType::Grid),
            FunctionType::Int(ContainerVariantType::Graph),
            FunctionType::Float(ContainerVariantType::Single),
        ] {
            b = call();
            b.return_type = ty;
            assert!(RustSignature::from_calls([&b]).is_err());
        }
    }

    #[test]
    fn language_defaults_and_fuel_are_bounded() {
        assert_eq!(Language::default(), Language::Cpp);
        assert!(serde_json::from_str::<Language>("\"python\"").is_err());
        assert_eq!(Language::Cpp.fuel_limit(Some(6)), Some(6));
        assert_eq!(Language::Rust.fuel_limit(Some(6)), Some(100_000));
        assert_eq!(Language::Rust.fuel_limit(Some(i64::MAX)), Some(1 << 48));
        assert_eq!(Language::Rust.fuel_limit(None), None);
    }
}
