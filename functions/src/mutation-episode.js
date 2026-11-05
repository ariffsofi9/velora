'use strict';
// Client expectations are preconditions, never an authorization source.
function mutationEpisode(data, ErrorType) {
  if (!data || typeof data !== 'object' || Array.isArray(data) ||
      !Object.hasOwn(data, 'expectedCafeId') || !Object.hasOwn(data, 'expectedMembershipGeneration') ||
      typeof data.expectedCafeId !== 'string' || data.expectedCafeId.length < 1 || data.expectedCafeId.length > 128 ||
      data.expectedCafeId.trim() !== data.expectedCafeId || /[\\/\p{Cc}]/u.test(data.expectedCafeId) ||
      ['.', '..'].includes(data.expectedCafeId) || !Number.isSafeInteger(data.expectedMembershipGeneration) ||
      data.expectedMembershipGeneration < 0) throw new ErrorType('invalid-argument', 'Workspace episode preconditions are required.');
  const {expectedCafeId, expectedMembershipGeneration, ...payload} = data;
  return {episode: {expectedCafeId, expectedMembershipGeneration}, payload};
}
function assertMutationEpisode(episode, cafeId, generation, ErrorType) {
  if (episode.expectedCafeId !== cafeId || episode.expectedMembershipGeneration !== generation) {
    throw new ErrorType('aborted', 'Workspace membership changed. Reload before retrying.');
  }
}
module.exports = {mutationEpisode, assertMutationEpisode};
