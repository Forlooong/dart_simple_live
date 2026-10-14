use crate::{
    wire::{self, Value},
    Error, Result,
};
use aho_corasick::{AhoCorasick, AhoCorasickBuilder, AhoCorasickKind};
use regress::{BudgetedMatch, Flags, Regex};

const RULE_BUDGET: u64 = 100_000;
const BATCH_BUDGET: u64 = 1_000_000;

#[derive(Default)]
pub struct Filter {
    version: u64,
    literals: Option<AhoCorasick>,
    empty_literal: bool,
    regexes: Vec<Regex>,
    quarantined: bool,
}

impl Filter {
    pub fn replace(&mut self, input: &Value) -> Result<Value> {
        wire::version(input)?;
        let version = input.get("version").u64()?;
        let rules = input.get("rules").array()?;
        let text_bytes = rules.iter().try_fold(0usize, |size, rule| {
            size.checked_add(rule.get("text").bytes()?.len())
                .ok_or_else(|| Error::limit("rule text byte overflow"))
        })?;
        let mut next = Self {
            version,
            ..Default::default()
        };
        let mut unsupported = Vec::new();
        let mut diagnostics = Vec::new();
        let mut patterns = Vec::new();
        if rules.len() > 2000 {
            next.quarantined = true;
            diagnostics.push(Value::Text(
                "rule count exceeds 2000; stored rules must be retained".into(),
            ));
        } else if text_bytes > 1024 * 1024 {
            next.quarantined = true;
            diagnostics.push(Value::Text(
                "combined rule text exceeds 1 MiB; stored rules must be retained".into(),
            ));
        } else {
            for (index, rule) in rules.iter().enumerate() {
                let units = rule.get("text").units()?;
                let regex = rule.get("regex").bool()?;
                if units.len() > 4096 {
                    next.quarantined = true;
                    diagnostics.push(Value::Text(format!(
                        "rule {index} exceeds 4096 UTF-16 units; stored rule must be retained"
                    )));
                    continue;
                }
                if regex {
                    match Regex::from_unicode(units.iter().map(|c| *c as u32), Flags::default()) {
                        Ok(regex) => next.regexes.push(regex),
                        Err(_) => unsupported.push(wire::int(index as u64)),
                    }
                } else if units.is_empty() {
                    next.empty_literal = true;
                } else {
                    patterns.push(rule.get("text").bytes()?.to_vec());
                }
            }
        }
        if !patterns.is_empty() && !next.quarantined {
            next.literals = Some(
                AhoCorasickBuilder::new()
                    .kind(Some(AhoCorasickKind::ContiguousNFA))
                    .build(patterns)
                    .map_err(|_| Error::limit("literal matcher construction limit"))?,
            );
        }
        let blocked = next.quarantined;
        // Atomic replacement: parse/build failure above leaves the prior rules intact.
        *self = next;
        Ok(wire::map([
            ("v", wire::int(1)),
            ("version", wire::int(version)),
            ("unsupported", Value::Array(unsupported)),
            ("invalid", Value::Array(Vec::new())),
            ("blocked", Value::Bool(blocked)),
            ("diagnostics", Value::Array(diagnostics)),
        ]))
    }

    pub fn apply(&mut self, input: &Value) -> Result<Value> {
        wire::version(input)?;
        let version = input.get("version").u64()?;
        if version != self.version {
            return Err(Error::request("stale filter version"));
        }
        let texts = input.get("texts").array()?;
        if texts.len() > 200 {
            return Err(Error::limit("filter batch exceeds 200 messages"));
        }
        let mut size = 0usize;
        for text in texts {
            let bytes = text.bytes()?;
            size = size
                .checked_add(bytes.len())
                .ok_or_else(|| Error::limit("filter input size overflow"))?;
            if bytes.len() % 2 != 0 {
                return Err(Error::request("odd UTF-16 byte length"));
            }
        }
        if size > 1024 * 1024 {
            return Err(Error::limit("filter batch exceeds 1 MiB"));
        }
        let mut keep = vec![false; texts.len()];
        let mut diagnostics = Vec::new();
        let mut remaining = BATCH_BUDGET;
        if !self.quarantined {
            'messages: for (i, text) in texts.iter().enumerate() {
                let bytes = text.bytes()?;
                if self.empty_literal {
                    continue;
                }
                // UTF-16LE matching must start at a code-unit boundary. Overlapping
                // search is essential: an unaligned hit must not hide an aligned one.
                if self
                    .literals
                    .as_ref()
                    .is_some_and(|ac| ac.find_overlapping_iter(bytes).any(|m| m.start() % 2 == 0))
                {
                    continue;
                }
                let units = wire::from_bytes(bytes)?;
                for regex in &self.regexes {
                    let (outcome, used) =
                        regex.find_from_ucs2_budgeted(&units, 0, RULE_BUDGET.min(remaining));
                    remaining = remaining.saturating_sub(used);
                    match outcome {
                        BudgetedMatch::Match(_) => continue 'messages,
                        BudgetedMatch::NoMatch => {}
                        BudgetedMatch::BudgetExhausted => {
                            self.quarantined = true;
                            diagnostics.push(Value::Text("regex execution budget exhausted; current rules version quarantined".into()));
                            break 'messages;
                        }
                    }
                }
                keep[i] = true;
            }
        }
        // Never partially pass a batch after a budget failure.
        if self.quarantined {
            keep.fill(false);
        }
        Ok(wire::map([
            ("v", wire::int(1)),
            ("version", wire::int(version)),
            (
                "keep",
                Value::Array(keep.into_iter().map(Value::Bool).collect()),
            ),
            ("quarantined", Value::Bool(self.quarantined)),
            ("diagnostics", Value::Array(diagnostics)),
        ]))
    }
}
