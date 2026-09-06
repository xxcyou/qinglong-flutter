class AiPlanAction {
  const AiPlanAction({
    this.type = '',
    this.target = '',
    this.impact = '',
    this.reversible = true,
    this.data,
  });

  final String type;
  final String target;
  final String impact;
  final bool reversible;
  final Map<String, dynamic>? data;
}

class AiPlan {
  const AiPlan({this.actions = const [], this.confirmed = false});

  final List<AiPlanAction> actions;
  final bool confirmed;

  AiPlan copyWith({List<AiPlanAction>? actions, bool? confirmed}) {
    return AiPlan(
      actions: actions ?? this.actions,
      confirmed: confirmed ?? this.confirmed,
    );
  }
}
