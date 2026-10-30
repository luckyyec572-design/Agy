"""Lossless model/effort catalog built only from the CLI's advertised variants."""
import re

EFFORTS = ("low", "medium", "high", "xhigh", "max")


def split_model(model):
    match = re.fullmatch(r"(.+)\s+\((Low|Medium|High|Xhigh|Max)\)", model["name"], re.I)
    if match:
        effort = match[2].lower()
        if model["id"].endswith("-" + effort):
            return model["id"][:-(len(effort)+1)], match[1], effort
    return model["id"], model["name"], ""


def families(models):
    result = {}
    for model in models:
        base, name, effort = split_model(model)
        item = result.setdefault(base, {"id": base, "name": name, "variants": [], "efforts": []})
        item["variants"].append({"id": model["id"], "effort": effort})
        if effort not in item["efforts"]:
            item["efforts"].append(effort)
    for item in result.values():
        item["efforts"].sort(key=lambda e: EFFORTS.index(e) if e in EFFORTS else -1)
        item["defaultEffort"] = "medium" if "medium" in item["efforts"] else item["efforts"][0]
    return list(result.values())


def resolve(models, model, effort=None):
    if effort is None and not any(m["id"] == model for m in models):
        family = next((f for f in families(models) if f["id"] == model), None)
        if family is not None: effort = family["defaultEffort"]
    for candidate in models:
        base, _, candidate_effort = split_model(candidate)
        if candidate["id"] == model and effort is None:
            return candidate["id"], base, candidate_effort
        if base == model and candidate_effort == (effort or ""):
            return candidate["id"], base, candidate_effort
    raise ValueError("模型或思考强度不可用，请刷新列表")
