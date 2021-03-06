from __future__ import print_function

import collections
import itertools
import logging
from typing import Any, Dict, Iterable, List, Optional, Set, Union

import pkg_resources
import six

from req_compile.containers import RequirementContainer
from req_compile.repos import Repository
from req_compile.utils import (
    merge_requirements,
    normalize_project_name,
    parse_requirement,
)


class DependencyNode(object):
    """
    Class representing a node in the dependency graph of a resolution. Contains information
    about whether or not this node has a solution yet -- meaning, is it resolved to a
    concrete requirement resolved from a Repository
    """

    def __init__(self, key, metadata):
        # type: (str, Optional[RequirementContainer]) -> None
        self.key = key
        self.metadata = metadata
        self.dependencies = (
            {}
        )  # type: Dict[DependencyNode, Optional[pkg_resources.Requirement]]
        self.reverse_deps = set()  # type: Set[DependencyNode]
        self.repo = None  # type: Optional[Repository]
        self.complete = (
            False  # Whether this node and all of its dependency are completely solved
        )

    def __repr__(self):
        # type: () -> str
        return self.key

    def __str__(self):
        # type: () -> str
        if self.metadata is None:
            return self.key + " [UNSOLVED]"
        if self.metadata.meta:
            return self.metadata.name
        return "==".join(str(x) for x in self.metadata.to_definition(self.extras))

    def __lt__(self, other):
        # type: (Any) -> bool
        return self.key < other.key

    @property
    def extras(self):
        # type: () -> Set[str]
        extras = set()
        for rdep in self.reverse_deps:
            assert (
                rdep.metadata is not None
            ), "Reverse dependency should already have a solution"
            reason = rdep.dependencies[self]
            if reason is not None:
                extras |= set(reason.extras)
        return extras

    def add_reason(self, node, reason):
        # type: (DependencyNode, Optional[pkg_resources.Requirement]) -> None
        self.dependencies[node] = reason

    def build_constraints(self):
        # type: () -> pkg_resources.Requirement
        result = None

        for rdep_node in self.reverse_deps:
            assert (
                rdep_node.metadata is not None
            ), "Reverse dependency should already have a solution"
            all_reqs = set(rdep_node.metadata.requires())
            for extra in rdep_node.extras:
                all_reqs |= set(rdep_node.metadata.requires(extra=extra))
            for req in all_reqs:
                if normalize_project_name(req.project_name) == self.key:
                    result = merge_requirements(result, req)

        if result is None:
            if self.metadata is None:
                result = parse_requirement(self.key)
            else:
                result = parse_requirement(self.metadata.name)
            assert result is not None

            if self.extras:
                result.extras = self.extras
                # Reparse to create a correct hash
                result = parse_requirement(str(result))
                assert result is not None
        return result


def _build_constraints(root_node):
    # type: (DependencyNode) -> Iterable[str]
    constraints = []  # type: List[str]
    for node in root_node.reverse_deps:
        assert (
            node.metadata is not None
        ), "Reverse dependency should already have a solution"
        all_reqs = set(node.metadata.requires())
        for extra in node.extras:
            all_reqs |= set(node.metadata.requires(extra=extra))
        for req in all_reqs:
            if normalize_project_name(req.project_name) == root_node.key:
                _process_constraint_req(req, node, constraints)
    return constraints


def _process_constraint_req(req, node, constraints):
    # type: (pkg_resources.Requirement, DependencyNode, List[str]) -> None
    assert node.metadata is not None, "Node {} must be solved".format(node)
    extra = None
    if req.marker:
        for marker in req.marker._markers:  # pylint: disable=protected-access
            if (
                isinstance(marker, tuple)
                and marker[0].value == "extra"
                and marker[1].value == "=="
            ):
                extra = marker[2].value
    source = node.metadata.name + (("[" + extra + "]") if extra else "")
    specifics = " (" + str(req.specifier) + ")" if req.specifier else ""  # type: ignore[attr-defined]
    constraints.extend([source + specifics])


class DistributionCollection(object):
    """A collection of dependencies and their distributions. This is the main representation
    of the graph of dependencies when putting together a resolution. As distributions are
    added to the collection and provide a concrete RequirementContainer (like a DistInfo from
    a wheel), the corresponding node in this collection will be marked solved."""

    def __init__(self):
        # type: () -> None
        self.nodes = {}  # type: Dict[str, DependencyNode]
        self.logger = logging.getLogger("req_compile.dists")

    @staticmethod
    def _build_key(name):
        return normalize_project_name(name)

    def add_dist(
        self,
        name_or_metadata,  # type: Union[str, RequirementContainer]
        source,  # type: Optional[DependencyNode]
        reason,  # type: Optional[pkg_resources.Requirement]
    ):
        # type: (...) -> Set[DependencyNode]
        """
        Add a distribution as a placeholder or as a solution

        Args:
            name_or_metadata: Distribution info to add, or if it is unknown, the
                name of hte distribution so it can be added as a placeholder
            source: The source of the distribution. This is used to build the graph
            reason: The requirement that caused this distribution to be added to the
                graph. This is used to constrain which solutions will be allowed
        """
        self.logger.debug("Adding dist: %s %s %s", name_or_metadata, source, reason)

        if isinstance(name_or_metadata, six.string_types):
            req_name = name_or_metadata
            metadata_to_apply = None
        else:
            metadata_to_apply = name_or_metadata
            req_name = metadata_to_apply.name

        key = DistributionCollection._build_key(req_name)

        if key in self.nodes:
            node = self.nodes[key]
        else:
            node = DependencyNode(key, metadata_to_apply)
            self.nodes[key] = node

        # If a new extra is being supplied, update the metadata
        if (
            reason
            and node.metadata
            and reason.extras
            and set(reason.extras) - node.extras
        ):
            metadata_to_apply = node.metadata

        if source is not None and source.key in self.nodes:
            node.reverse_deps.add(source)
            source.add_reason(node, reason)

        nodes = set()
        if metadata_to_apply is not None:
            nodes |= self._update_dists(node, metadata_to_apply)

        self._discard_metadata_if_necessary(node, reason)

        if node.key not in self.nodes:
            raise ValueError("The node {} is gone, while adding".format(node.key))

        return nodes

    def _discard_metadata_if_necessary(self, node, reason):
        if node.metadata is not None and not node.metadata.meta and reason is not None:
            if node.metadata.version is not None and not reason.specifier.contains(
                node.metadata.version, prereleases=True
            ):
                self.logger.debug(
                    "Existing solution (%s) invalidated by %s", node.metadata, reason
                )
                # Discard the metadata
                self.remove_dists(node, remove_upstream=False)

    def _update_dists(self, node, metadata):
        node.metadata = metadata
        add_nodes = {node}
        for extra in {None} | node.extras:
            for req in metadata.requires(extra):
                # This adds a placeholder entry
                add_nodes |= self.add_dist(req.name, node, req)
        return add_nodes

    def remove_dists(self, node, remove_upstream=True):
        # type: (Union[DependencyNode, Iterable[DependencyNode]], bool) -> None
        if isinstance(node, collections.Iterable):
            for single_node in node:
                self.remove_dists(single_node, remove_upstream=remove_upstream)
            return

        self.logger.info("Removing dist(s): %s (upstream = %s)", node, remove_upstream)

        if node.key not in self.nodes:
            self.logger.debug("Node %s was already removed", node.key)
            return

        if remove_upstream:
            del self.nodes[node.key]
            for reverse_dep in node.reverse_deps:
                del reverse_dep.dependencies[node]

        for dep in node.dependencies:
            if remove_upstream or dep.key != node.key:
                dep.reverse_deps.remove(node)
                if not dep.reverse_deps:
                    self.remove_dists(dep)

        if not remove_upstream:
            node.dependencies = {}
            node.metadata = None
            node.complete = False

    def build(self, roots):
        results = self.generate_lines(roots)
        return [
            parse_requirement("==".join([result[0][0], str(result[0][1])]))
            for result in results
        ]

    def visit_nodes(
        self, roots, max_depth=None, reverse=False, _visited=None, _cur_depth=0
    ):
        if _visited is None:
            _visited = set()

        if reverse:
            next_nodes = itertools.chain(*[root.reverse_deps for root in roots])
        else:
            next_nodes = itertools.chain(*[root.dependencies.keys() for root in roots])
        for node in next_nodes:
            if node in _visited:
                continue

            _visited.add(node)
            yield node

            if max_depth is None or _cur_depth < max_depth - 1:
                results = self.visit_nodes(
                    [node],
                    reverse=reverse,
                    max_depth=max_depth,
                    _visited=_visited,
                    _cur_depth=_cur_depth + 1,
                )
                for result in results:
                    yield result

    def generate_lines(self, roots, req_filter=None, _visited=None):
        """
        Generate the lines of a results file from this collection
        Args:
            roots (iterable[DependencyNode]): List of roots to generate lines from
            req_filter (Callable): Filter to apply to each element of the collection.
                Return True to keep a node, False to exclude it
            _visited (set): Internal set to make sure each node is only visited once
        Returns:
            (list[str]) List of rendered node entries in the form of
                reqname==version   # reasons
        """
        req_filter = req_filter or (lambda _: True)
        results = []
        for node in self.visit_nodes(roots):
            if node.metadata is None:
                continue
            if not node.metadata.meta and req_filter(node):
                constraints = _build_constraints(node)
                req_expr = node.metadata.to_definition(node.extras)
                constraint_text = ", ".join(sorted(constraints))
                results.append((req_expr, constraint_text))
        return results

    def __contains__(self, project_name):
        req_name = project_name.split("[")[0]
        return normalize_project_name(req_name) in self.nodes

    def __iter__(self):
        return iter(self.nodes.values())

    def __getitem__(self, project_name):
        req_name = project_name.split("[")[0]
        return self.nodes[normalize_project_name(req_name)]
