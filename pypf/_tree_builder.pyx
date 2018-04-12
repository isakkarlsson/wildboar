# cython: cdivision=True
# cython: boundscheck=False
# cython: wraparound=False

# This file is part of pypf
#
# pypf is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# pypf is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
# License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.

# Authors: Isak Karlsson

"""
Construct a shapelet based decision tree.
"""

import numpy as np
cimport numpy as np

from libc.math cimport log2
from libc.math cimport INFINITY
from libc.math cimport NAN

from libc.stdlib cimport malloc
from libc.stdlib cimport free

from libc.string cimport memcpy
from libc.string cimport memset

from pypf._sliding_distance cimport SlidingDistance
from pypf._sliding_distance cimport ShapeletInfo
from pypf._sliding_distance cimport Shapelet
from pypf._sliding_distance cimport shapelet_info_update_statistics
from pypf._sliding_distance cimport shapelet_info_scaled_distances
from pypf._sliding_distance cimport shapelet_info_scaled_distance
from pypf._sliding_distance cimport shapelet_info_distance
from pypf._sliding_distance cimport shapelet_info_distances
from pypf._sliding_distance cimport shapelet_info_extract_scaled_shapelet
from pypf._sliding_distance cimport shapelet_info_extract_shapelet

from pypf._sliding_distance cimport new_sliding_distance
from pypf._sliding_distance cimport free_sliding_distance

from pypf._impurity cimport info

from pypf._utils cimport label_distribution
from pypf._utils cimport print_c_array_d
from pypf._utils cimport argsort
from pypf._utils cimport rand_int
from pypf._utils cimport RAND_R_MAX


cdef SplitPoint new_split_point(size_t split_point,
                                double threshold,
                                ShapeletInfo shapelet_info) nogil:
    cdef SplitPoint s
    s.split_point = split_point
    s.threshold = threshold
    s.shapelet_info = shapelet_info
    return s


# pickle a leaf node
cpdef Node remake_leaf_node(size_t n_labels, object proba):
    cdef Node node = Node(True)
    cdef size_t i
    node.n_labels = n_labels
    node.distribution = <double*> malloc(sizeof(double) * n_labels)
    for i in range(<size_t> proba.shape[0]):
        node.distribution[i] = proba[i]
    return node

# pickle a branch node
cpdef Node remake_branch_node(double threshold, Shapelet shapelet,
                              Node left, Node right):
    cpdef Node node = Node(False)
    node.shapelet = shapelet
    node.threshold = threshold
    node.left = left
    node.right = right
    return node


cdef class Node:
    def __cinit__(self, bint is_leaf):
        self.is_leaf = is_leaf
        self.distribution = NULL

    def __dealloc__(self):
        if self.is_leaf and self.distribution != NULL:
            free(self.distribution)
            self.distribution = NULL

    def __reduce__(self):
        if self.is_leaf:
            return (remake_leaf_node,
                    (self.n_labels, self.proba))
        else:
            return (remake_branch_node, (self.threshold,
                                         self.shapelet, self.left, self.right))

    @property
    def proba(self):
        if not self.is_leaf:
            raise AttributeError("not a leaf node")

        cdef np.ndarray[np.float64_t] arr = np.empty(
            self.n_labels, dtype=np.float64)

        cdef size_t i
        for i in range(self.n_labels):
            arr[i] = self.distribution[i]
        return arr


cdef Node new_leaf_node(double* label_buffer, size_t n_labels,
                        double n_weighted_samples):
    cdef double* distribution = <double*> malloc(sizeof(double) * n_labels)
    cdef size_t i
    for i in range(n_labels):
        distribution[i] = label_buffer[i] / n_weighted_samples

    cdef Node node = Node(True)
    node.distribution = distribution
    node.n_labels = n_labels
    return node


cdef Node new_branch_node(SplitPoint sp, Shapelet shapelet):
    cdef Node node = Node(False)
    node.threshold = sp.threshold
    node.shapelet = shapelet
    return node


cdef class ShapeletTreePredictor:
    cdef size_t n_labels
    cdef SlidingDistance sd

    def __cinit__(self,
                  np.ndarray[np.float64_t, ndim=2, mode="c"] X,
                  size_t n_labels):
        """Construct a shapelet tree predictor

        :param X: the data to predict over
        :param size_t n_labels: the number of labels
        """
        self.n_labels = n_labels
        self.sd = new_sliding_distance(X)

    def __dealloc__(self):
        free_sliding_distance(self.sd)

    def predict_proba(self, Node root):
        """Predict the probability of each label using the tree described by
        `root`

        :param root: the root node
        :returns: the probabilities of shape `[n_samples, n_labels]`
        """
        cdef size_t i
        cdef size_t n_samples = self.sd.n_samples
        cdef np.ndarray[np.float64_t, ndim=2] output = np.empty(
            [n_samples, self.n_labels], dtype=np.float64)
        cdef Node node
        cdef Shapelet shapelet
        cdef double threshold
        for i in range(n_samples):
            node = root
            while not node.is_leaf:
                shapelet = node.shapelet
                threshold = node.threshold
                if shapelet.distance(self.sd, i) <= threshold:
                    node = node.left
                else:
                    node = node.right
            output[i, :] = node.proba
        return output


cdef class ShapeletTreeBuilder:
    cdef size_t random_seed
    cdef size_t n_shapelets
    cdef size_t max_depth
    cdef bint scale

    cdef size_t* labels
    cdef size_t label_stride
    cdef size_t n_labels

    cdef double* sample_weights

    cdef size_t n_samples
    cdef size_t* samples
    cdef size_t* samples_buffer
    cdef double n_weighted_samples

    cdef double* distance_buffer

    cdef double* label_buffer
    cdef double* left_label_buffer
    cdef double* right_label_buffer

    cdef SlidingDistance sd

    # TODO: Add more parameters
    #  * min_size
    #  * max_size
    #  * max_depth
    #  * min_samples_leaf
    #  * ...
    def __cinit__(self,
                  size_t n_shapelets,
                  size_t max_depth,
                  bint scale,
                  object random_state):
        self.scale = scale
        self.random_seed = random_state.randint(0, RAND_R_MAX)
        self.n_shapelets = n_shapelets
        self.max_depth = max_depth

    def __dealloc__(self):
        self._free_if_needed()

    cdef void _free_if_needed(self) nogil:
        if self.sd.X_buffer != NULL:
            free_sliding_distance(self.sd)

        if self.samples != NULL:
            free(self.samples)
            self.samples = NULL

        if self.samples_buffer != NULL:
            free(self.samples_buffer)
            self.samples_buffer = NULL

        if self.distance_buffer != NULL:
            free(self.distance_buffer)
            self.distance_buffer = NULL

        if self.label_buffer != NULL:
            free(self.label_buffer)
            self.label_buffer = NULL

        if self.left_label_buffer != NULL:
            free(self.left_label_buffer)
            self.left_label_buffer = NULL

        if self.right_label_buffer != NULL:
            free(self.right_label_buffer)
            self.right_label_buffer = NULL

    # this is unchecked
    cpdef void init(self,
                    np.ndarray[np.float64_t, ndim=2, mode="c"] X,
                    np.ndarray[np.intp_t, ndim=1, mode="c"] y,
                    size_t n_labels,
                    np.ndarray[np.float64_t, ndim=1, mode="c"] sample_weights):

        self._free_if_needed()

        self.labels = <size_t*> y.data # labels are unallocated automatically
        self.label_stride = <size_t> y.strides[0] / <size_t> y.itemsize

        self.n_samples = X.shape[0]
        self.samples = <size_t*> malloc(sizeof(size_t) * self.n_samples)
        self.samples_buffer = <size_t*> malloc(sizeof(size_t) * self.n_samples)
        self.distance_buffer = <double*> malloc(
            sizeof(double) * self.n_samples)

        self.n_labels = n_labels
        self.label_buffer = <double*> malloc(sizeof(double) * n_labels)
        self.left_label_buffer = <double*> malloc(sizeof(double) * n_labels)
        self.right_label_buffer= <double*> malloc(sizeof(double) * n_labels)

        if (self.samples == NULL or
            self.distance_buffer == NULL or
            self.samples_buffer == NULL or
            self.left_label_buffer == NULL or
            self.right_label_buffer == NULL or
            self.label_buffer == NULL):
            raise MemoryError()

        cdef size_t i
        cdef size_t j = 0
        for i in range(self.n_samples):
            if sample_weights is None or sample_weights[i] != 0.0:
                self.samples[j] = i
                j += 1

        self.n_samples = j
        self.n_weighted_samples = 0

        self.sd = new_sliding_distance(X)

        if sample_weights is None:
            self.sample_weights = NULL
        else:
            self.sample_weights = <double*> sample_weights.data  # unallocated

    cpdef Node build_tree(self):
        return self._build_tree(0, self.n_samples, 0)

    cdef Node _build_tree(self, size_t start, size_t end, size_t depth):
        memset(self.label_buffer, 0, sizeof(double) * self.n_labels)
        cdef int n_positive = label_distribution(self.samples,
                                                 self.sample_weights,
                                                 start,
                                                 end,
                                                 self.labels,
                                                 self.label_stride,
                                                 self.n_labels,
                                                 &self.n_weighted_samples,
                                                 self.label_buffer)
        if end - start < 2 or n_positive < 2 or depth >= self.max_depth:
            return new_leaf_node(
                self.label_buffer, self.n_labels, self.n_weighted_samples)

        cdef SplitPoint split = self._split(start, end)

        cdef Shapelet shapelet
        cdef Node branch

        cdef double prev_dist
        cdef double curr_dist
        if split.split_point > start and end - split.split_point > 0:
            if self.scale:
                shapelet = shapelet_info_extract_scaled_shapelet(
                    split.shapelet_info, self.sd)
            else:
                shapelet = shapelet_info_extract_shapelet(
                    split.shapelet_info, self.sd)

            branch = new_branch_node(split, shapelet)
            branch.left = self._build_tree(start, split.split_point, depth + 1)
            branch.right = self._build_tree(split.split_point, end, depth + 1)
            return branch
        else:
            return new_leaf_node(
                self.label_buffer, self.n_labels, self.n_weighted_samples)

    cdef SplitPoint _split(self, size_t start, size_t end) nogil:
        cdef size_t split_point, best_split_point
        cdef double threshold, best_threshold
        cdef double impurity
        cdef double best_impurity
        cdef ShapeletInfo shapelet
        cdef ShapeletInfo best_shapelet
        cdef size_t i

        best_impurity = INFINITY
        for i in range(self.n_shapelets):
            shapelet = self._sample_shapelet(start, end)
            if self.scale:
                shapelet_info_scaled_distances(shapelet,
                                               self.samples + start,
                                               end - start,
                                               self.sd,
                                               self.distance_buffer + start)
            else:
                shapelet_info_distances(shapelet,
                                        self.samples + start,
                                        end - start,
                                        self.sd,
                                        self.distance_buffer + start)


            # sort the distances and the samples in increasing order
            # of distance
            argsort(self.distance_buffer + start,
                    self.samples + start, end - start)
            self._partition_distance_buffer(
                start, end, &split_point, &threshold, &impurity)
            if impurity < best_impurity:
                # store the order of samples in `sample_buffer`
                memcpy(self.samples_buffer,
                       self.samples + start, sizeof(size_t) * (end - start))
                best_impurity = impurity
                best_split_point = split_point
                best_threshold = threshold
                best_shapelet = shapelet

        # restore the best order to `samples`
        memcpy(self.samples + start,
               self.samples_buffer, sizeof(size_t) * (end - start))
        return new_split_point(best_split_point, best_threshold, best_shapelet)

    cdef ShapeletInfo _sample_shapelet(self, size_t start, size_t end) nogil:
        cdef ShapeletInfo shapelet_info

        shapelet_info.length = rand_int(
            2, self.sd.n_timestep, &self.random_seed)
        shapelet_info.start = rand_int(
            0, self.sd.n_timestep - shapelet_info.length, &self.random_seed)
        shapelet_info.index = self.samples[rand_int(
            start, end, &self.random_seed)]

        if self.scale:
            shapelet_info_update_statistics(&shapelet_info, self.sd)
        return shapelet_info

    cdef void _partition_distance_buffer(self,
                                         size_t start,
                                         size_t end,
                                         size_t* split_point,
                                         double* threshold,
                                         double* impurity) nogil:
        memset(self.left_label_buffer, 0, sizeof(double) * self.n_labels)

        # store the label buffer temporarily in `right_label_buffer`
        memcpy(self.right_label_buffer, self.label_buffer,
               sizeof(double) * self.n_labels)

        cdef size_t i # real index of samples
        cdef size_t j # sample index
        cdef size_t p # label index

        cdef double right_sum
        cdef double left_sum

        cdef double prev_distance
        cdef size_t prev_label

        cdef double current_sample_weight
        cdef double current_distance
        cdef double current_impurity
        cdef size_t current_label

        j = self.samples[start]
        p = j * self.label_stride

        prev_distance = self.distance_buffer[start]
        prev_label = self.labels[j]

        if self.sample_weights != NULL:
            current_sample_weight = self.sample_weights[j]
        else:
            current_sample_weight = 1.0

        left_sum = current_sample_weight
        right_sum = self.n_weighted_samples - current_sample_weight

        self.left_label_buffer[prev_label] += current_sample_weight
        self.right_label_buffer[prev_label] -= current_sample_weight

        impurity[0] = info(left_sum,
                           self.left_label_buffer,
                           right_sum,
                           self.right_label_buffer,
                           self.n_labels)

        threshold[0] = prev_distance / 2
        split_point[0] = start + 1 # The split point indicates a <=-relation

        for i in range(start + 1, end):
            j = self.samples[i]
            current_distance = self.distance_buffer[i]

            p = j * self.label_stride
            current_label = self.labels[p]

            if not current_label == prev_label:
                current_impurity = info(left_sum,
                                        self.left_label_buffer,
                                        right_sum,
                                        self.right_label_buffer,
                                        self.n_labels)

                if current_impurity <= impurity[0]:
                    impurity[0] = current_impurity
                    threshold[0] = (current_distance + prev_distance) / 2
                    split_point[0] = i

            if self.sample_weights != NULL:
                current_sample_weight = self.sample_weights[j]
            else:
                current_sample_weight = 1.0

            left_sum += current_sample_weight
            right_sum -= current_sample_weight
            self.left_label_buffer[current_label] += current_sample_weight
            self.right_label_buffer[current_label] -= current_sample_weight

            prev_label = current_label
            prev_distance = current_distance
