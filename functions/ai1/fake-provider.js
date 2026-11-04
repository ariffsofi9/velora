'use strict';

// Explicit fixture, not generated advice and never a fallback for provider errors.
async function fakeProvider({items}) {
  const banana = items.find((item) => item.name.toLowerCase() === 'banana');
  const milk = items.find((item) => item.name.toLowerCase() === 'milk');
  if (!banana || !milk) return [];
  return [{title: 'Banana Milk Smoothie', ingredientItemIds: [banana.id, milk.id],
    steps: ['Peel the banana.', 'Blend the banana with milk.', 'Serve immediately.'],
    whyRecommended: 'AI-1 test fixture using available banana and milk; not AI-generated.'}];
}
module.exports = {fakeProvider};
